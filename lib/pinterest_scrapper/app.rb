# frozen_string_literal: true

require "fileutils"
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
      :sqlite_database_file,
      :stopped_early,
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
          report_progress "#{collected_image_urls.length} original image URLs ready for database insert."
          close_pin_cursor
          inserted_image_urls = write_image_urls(collected_image_urls)
          duplicated_image_url_count = collected_image_urls.length - inserted_image_urls.length
          report_progress "#{collected_image_urls.length} total image URLs. #{inserted_image_urls.length} inserted. #{duplicated_image_url_count} duplicated."

          wait_until_unlocked
          download_result = download_images(inserted_image_urls)
          saved_image_files.concat(download_result.saved_files)
          skipped_image_files.concat(download_result.skipped_files)
          failed_image_urls.concat(download_result.failed_urls)

          if stop_requested?
            report_progress "Stop requested. Marking current pin as interrupted."
            close_pin_cursor
            write_interrupted_pins(status_pin_records([next_url, last_scraped_page.pin_url], interrupted: true))
            report_progress "Current pin marked interrupted."
            stopped_early = true
            break
          end

          inserted_pin_count = write_pins(pin_records(collected_pin_urls))
          duplicated_pin_count = collected_pin_urls.length - inserted_pin_count
          report_progress "#{collected_pin_urls.length} total pin URLs. #{inserted_pin_count} inserted. #{duplicated_pin_count} duplicated."

          write_processed_pins(status_pin_records([next_url, last_scraped_page.pin_url], processed: true))

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

        image_original_urls = stopped_early ? [] : sqlite_store.load_image_urls
        pin_urls = stopped_early ? [] : load_pin_urls
        image_original_url_count = stopped_early ? nil : image_original_urls.length
        pin_url_count = stopped_early ? nil : pin_urls.length

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
          sqlite_database_file: sqlite_store.database_file,
          stopped_early: stopped_early
        )
      ensure
        close_pin_cursor
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

    def download_images(image_urls)
      report_progress "Downloading #{image_urls.length} original images..."
      result = image_downloader.download_all(
        image_urls,
        target_folder,
        progress: progress,
        stop_requested: method(:stop_requested?)
      )
      report_progress "Saved #{result.saved_files.length} images. Skipped #{result.skipped_files.length}. Failed #{result.failed_urls.length}."
      result
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

    def write_image_urls(image_urls)
      sqlite_store.write_image_urls(image_urls, progress: progress)
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
  end
end
