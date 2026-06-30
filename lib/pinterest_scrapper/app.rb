# frozen_string_literal: true

require "fileutils"
require "thread"
require "uri"

require_relative "browser_opener"
require_relative "image_downloader"
require_relative "page_fetcher"
require_relative "safari_snapshot"
require_relative "scraper"
require_relative "session_lock"
require_relative "sqlite_store"

module PinterestScrapper
  class App
    Result = Struct.new(
      :target_folder,
      :pinterest_url,
      :pin_url,
      :pin_urls,
      :pin_url_count,
      :urls,
      :image_original_urls,
      :image_original_url_count,
      :saved_image_files,
      :skipped_image_files,
      :failed_image_urls,
      :image_saved_count,
      :image_inserted_count,
      :image_failed_count,
      :sqlite_database_file,
      :stopped_early,
      keyword_init: true
    )

    ImageCounters = Struct.new(:saved, :inserted, :failed, keyword_init: true) do
      def self.zero
        new(saved: 0, inserted: 0, failed: 0)
      end

      def add(other)
        self.saved += other.saved
        self.inserted += other.inserted
        self.failed += other.failed
      end
    end

    ImageProcessingResult = Struct.new(
      :saved_files,
      :skipped_files,
      :failed_urls,
      :counters,
      keyword_init: true
    )

    def initialize(
      target_folder:,
      pinterest_url:,
      browser_opener: BrowserOpener.new,
      page_fetcher: PageFetcher.new,
      safari_snapshot: SafariSnapshot.new,
      image_downloader: ImageDownloader.new,
      session_lock: SessionLock.new,
      lock_check_interval: SessionLock::CHECK_INTERVAL_SECONDS,
      sqlite_store: nil,
      progress: nil,
      stop_requested: nil
    )
      @target_folder = target_folder
      @pinterest_url = pinterest_url
      @browser_opener = browser_opener
      @page_fetcher = page_fetcher
      @safari_snapshot = safari_snapshot
      @image_downloader = image_downloader
      @session_lock = session_lock
      @lock_check_interval = lock_check_interval
      @sqlite_store = sqlite_store || SQLiteStore.new(target_folder: target_folder)
      @progress = progress
      @stop_requested = stop_requested
    end

    def run
      begin
        FileUtils.mkdir_p(target_folder)
        sqlite_store.setup
        saved_image_files = []
        skipped_image_files = []
        failed_image_urls = []
        image_counters = ImageCounters.zero
        last_scraped_page = nil
        next_url = pinterest_url.to_s
        stopped_early = false

        loop do
          if stop_requested?
            report_progress "Stop requested. Ending gracefully."
            stopped_early = true
            break
          end

          wait_until_unlocked
          last_scraped_page = scrape_page(next_url)
          collected_pin_urls = last_scraped_page.pin_urls
          collected_image_urls = last_scraped_page.image_original_urls
          close_pin_cursor

          wait_until_unlocked
          download_result = process_images(collected_image_urls)
          saved_image_files.concat(download_result.saved_files)
          skipped_image_files.concat(download_result.skipped_files)
          failed_image_urls.concat(download_result.failed_urls)
          image_counters.add(download_result.counters)
          report_progress image_counter_message("Pin image counters", download_result.counters)

          if stop_requested?
            report_progress "Stop requested. Marking current pin as interrupted."
            close_pin_cursor
            write_interrupted_pins(status_pin_records([next_url], interrupted: true))
            report_progress "Current pin marked interrupted."
            stopped_early = true
            break
          end

          inserted_pin_count = write_pins(pin_records(collected_pin_urls))
          duplicated_pin_count = collected_pin_urls.length - inserted_pin_count
          report_progress "#{collected_pin_urls.length} total pin URLs. #{inserted_pin_count} inserted. #{duplicated_pin_count} duplicated."

          write_processed_pins(status_pin_records([next_url], processed: true))
          wal_checkpoint

          if stop_requested?
            report_progress "Stop requested. Ending gracefully before the next pin."
            stopped_early = true
            break
          end

          next_pin_url = next_unprocessed_pin_url
          break unless next_pin_url

          next_url = next_pin_url
          report_progress "Processing next pin: #{next_url}"
        end

        image_original_urls = []
        pin_urls = []
        image_original_url_count = stopped_early ? nil : sqlite_store.image_url_count
        pin_url_count = stopped_early ? nil : sqlite_store.pin_count

        Result.new(
          target_folder: File.expand_path(target_folder),
          pinterest_url: pinterest_url.to_s,
          pin_url: pinterest_url.to_s,
          pin_urls: pin_urls,
          pin_url_count: pin_url_count,
          urls: image_original_urls,
          image_original_urls: image_original_urls,
          image_original_url_count: image_original_url_count,
          saved_image_files: saved_image_files.uniq,
          skipped_image_files: skipped_image_files.uniq,
          failed_image_urls: failed_image_urls,
          image_saved_count: image_counters.saved,
          image_inserted_count: image_counters.inserted,
          image_failed_count: image_counters.failed,
          sqlite_database_file: sqlite_store.database_file,
          stopped_early: stopped_early
        )
      ensure
        close_pin_cursor
        sqlite_store.close
      end
    end

    private

    attr_reader :target_folder,
                :pinterest_url,
                :browser_opener,
                :page_fetcher,
                :safari_snapshot,
                :image_downloader,
                :session_lock,
                :lock_check_interval,
                :sqlite_store,
                :progress,
                :stop_requested

    def wait_until_unlocked
      reported_locked = false

      while session_lock.locked?
        unless reported_locked
          report_progress "Machine is locked. Pausing until it is unlocked..."
          reported_locked = true
        end

        return if stop_requested?

        sleep lock_check_interval
      end

      report_progress "Machine unlocked. Resuming..." if reported_locked
    end

    def scrape_page(url)
      report_progress "Opening Safari and collecting rendered page URLs: #{url}"
      snapshot = safari_snapshot.capture(url, progress: progress)
      scraped_page = Scraper.new(snapshot.body, source_url: snapshot.url, extra_urls: snapshot.urls).scrape
      report_progress "Collected #{scraped_page.image_original_urls.length} original image URLs and #{scraped_page.pin_urls.length} pin URLs."
      scraped_page
    rescue StandardError => e
      report_progress "Safari collection failed: #{e.message}"
      report_progress "Falling back to the initial HTML response..."
      page = page_fetcher.fetch(url)
      scraped_page = Scraper.new(page.body, source_url: page.url).scrape
      report_progress "Collected #{scraped_page.image_original_urls.length} original image URLs and #{scraped_page.pin_urls.length} pin URLs."
      scraped_page
    end

    def report_progress(message)
      progress&.call(message)
    end

    def stop_requested?
      stop_requested&.call
    end

    def process_images(image_urls)
      report_progress "Processing #{image_urls.length} original images..."
      saved_files = []
      skipped_files = []
      failed_urls = []
      counters = ImageCounters.zero

      sqlite_store.with_image_url_transaction(progress: progress) do |transaction|
        worker_count = image_worker_count(image_urls.length)
        jobs = Queue.new
        results = Queue.new
        image_urls.each_with_index { |image_url, index| jobs << [image_url, index] }

        workers = worker_count.times.map do
          Thread.new do
            loop do
              image_url, index = jobs.pop(true)
              break if stop_requested?

              results << [image_url, save_image(image_url, index, image_urls.length)]
            rescue ThreadError
              break
            end

            results << :done
          end
        end

        finished_workers = 0
        while finished_workers < worker_count
          result = results.pop
          if result == :done
            finished_workers += 1
            next
          end

          image_url, image_result = result
          apply_image_result(transaction, image_url, image_result, saved_files, skipped_files, failed_urls, counters)
        end

        workers.each(&:join)
      end

      report_progress "Stop requested. Ending downloads gracefully." if stop_requested?
      result = ImageProcessingResult.new(
        saved_files: saved_files.uniq,
        skipped_files: skipped_files.uniq,
        failed_urls: failed_urls,
        counters: counters
      )
      report_progress "Saved #{result.saved_files.length} images. Skipped #{result.skipped_files.length}. Failed #{result.failed_urls.length}."
      result
    end

    def apply_image_result(transaction, image_url, image_result, saved_files, skipped_files, failed_urls, counters)
      if image_result.saved_file
        saved_files << image_result.saved_file
        counters.saved += 1
        if transaction.insert(image_url)
          counters.inserted += 1
        else
          counters.failed += 1
        end
      elsif image_result.skipped_file
        skipped_files << image_result.skipped_file
      elsif image_result.failed_url
        failed_urls << image_result.failed_url
        counters.failed += 1
      end
    end

    def image_counter_message(label, counters)
      "#{label}: saved #{counters.saved}. inserted #{counters.inserted}. failed #{counters.failed}."
    end

    def save_image(image_url, index, total)
      if image_downloader.respond_to?(:download_one)
        return image_downloader.download_one(
          image_url,
          target_folder,
          index: index,
          total: total,
          progress: progress
        )
      end

      result = image_downloader.download_all(
        [image_url],
        target_folder,
        progress: progress,
        stop_requested: method(:stop_requested?)
      )
      ImageDownloader::ImageResult.new(
        saved_file: result.saved_files.first,
        skipped_file: result.skipped_files.first,
        failed_url: result.failed_urls.first
      )
    end

    def image_worker_count(total)
      return image_downloader.worker_count_for(total) if image_downloader.respond_to?(:worker_count_for)

      [[ImageDownloader::DEFAULT_WORKERS, 1].max, total.to_i].min
    end

    def load_pin_urls
      sqlite_store.load_pins.map { |pin| pin.fetch("pin_url") }
    end

    def pin_records(pin_urls, processed: false, interrupted: false)
      pin_urls.compact.map do |pin_url|
        {
          "pin_url" => pin_url,
          "processed" => processed,
          "interrupted" => interrupted
        }
      end
    end

    def status_pin_records(pin_urls, processed: false, interrupted: false)
      pin_records(pin_urls.compact.uniq, processed: processed, interrupted: interrupted)
    end

    def next_unprocessed_pin_url
      interrupted_pin_url = sqlite_store.next_interrupted_pin_url
      return interrupted_pin_url if interrupted_pin_url

      loop do
        opened_cursor = @pin_cursor.nil?
        @pin_cursor ||= sqlite_store.random_unprocessed_pin_cursor
        pin_url = @pin_cursor.next_pin_url
        return pin_url if pin_url

        close_pin_cursor
        return nil if opened_cursor
      end
    end

    def close_pin_cursor
      @pin_cursor&.close
      @pin_cursor = nil
    end

    def write_pins(pins)
      sqlite_store.write_pins(pins, progress: progress)
    end

    def write_interrupted_pins(pins)
      sqlite_store.write_interrupted_pins(pins)
    end

    def write_processed_pins(pins)
      sqlite_store.write_processed_pins(pins)
    end

    def wal_checkpoint
      if sqlite_store.respond_to?(:wal_checkpoint_async)
        checkpoint_status = sqlite_store.wal_checkpoint_async(progress: ->(message) { report_progress message })
        case checkpoint_status
        when :started
          report_progress "WAL checkpoint started in background."
        when :running
          report_progress "WAL checkpoint already running; skipping this pin."
        end
      else
        checkpoint_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sqlite_store.wal_checkpoint
        elapsed_time = format("%.3f", Process.clock_gettime(Process::CLOCK_MONOTONIC) - checkpoint_start_time)
        report_progress "WAL checkpoint completed in #{elapsed_time}s."
      end
    end
  end
end
