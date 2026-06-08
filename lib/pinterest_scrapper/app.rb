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
      :urls,
      :image_original_urls,
      :saved_image_files,
      :skipped_image_files,
      :failed_image_urls,
      :sqlite_database_file,
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
      FileUtils.mkdir_p(target_folder)
      sqlite_store.setup
      url_manifest = load_url_manifest
      pins_manifest = load_pins_manifest
      saved_image_files = []
      skipped_image_files = []
      failed_image_urls = []
      last_scraped_page = nil
      next_url = pinterest_url.to_s
      pending_pin_urls = []
      add_seed_pin(pins_manifest, next_url)

      loop do
        if stop_requested?
          report_progress "Stop requested. Writing database and ending gracefully."
          write_state(url_manifest, pins_manifest)
          break
        end

        wait_until_unlocked
        last_scraped_page = scrape_page(next_url)
        newly_discovered_pin_urls = new_pin_urls(pins_manifest, pending_pin_urls, last_scraped_page.pin_urls)
        pending_pin_urls.concat(newly_discovered_pin_urls)
        report_progress "#{newly_discovered_pin_urls.length} new pin URLs queued for future runs." if newly_discovered_pin_urls.any?
        new_image_urls = add_image_urls(url_manifest, last_scraped_page.image_original_urls)
        already_known_image_count = last_scraped_page.image_original_urls.length - new_image_urls.length
        report_progress "#{new_image_urls.length} new original image URLs. #{already_known_image_count} already in database."
        write_state(url_manifest, pins_manifest)

        wait_until_unlocked
        download_result = download_images(new_image_urls)
        saved_image_files.concat(download_result.saved_files)
        skipped_image_files.concat(download_result.skipped_files)
        failed_image_urls.concat(download_result.failed_urls)

        if stop_requested?
          mark_pin_interrupted(pins_manifest, next_url)
          mark_pin_interrupted(pins_manifest, last_scraped_page.pin_url)
          report_progress "Stop requested. Marking current pin as interrupted."
          write_state(url_manifest, pins_manifest)
          break
        end

        mark_pin_processed(pins_manifest, next_url)
        mark_pin_processed(pins_manifest, last_scraped_page.pin_url)
        write_state(url_manifest, pins_manifest)

        if stop_requested?
          report_progress "Stop requested. Ending gracefully before the next pin."
          break
        end

        next_pin = next_unprocessed_pin(pins_manifest)
        break unless next_pin

        next_url = next_pin.fetch("pin_url")
        report_progress "Processing next pin: #{next_url}"
      end

      add_pins(pins_manifest, pending_pin_urls)
      report_progress "Added #{pending_pin_urls.length} new pins to database for future runs." if pending_pin_urls.any?
      write_state(url_manifest, pins_manifest)

      image_original_urls = url_manifest.fetch("image_original_urls")
      pin_urls = pins_manifest.fetch("pins").map { |pin| pin.fetch("pin_url") }

      Result.new(
        target_folder: File.expand_path(target_folder),
        pinterest_url: pinterest_url.to_s,
        pin_url: pinterest_url.to_s,
        pin_urls: pin_urls,
        urls: image_original_urls,
        image_original_urls: image_original_urls,
        saved_image_files: saved_image_files.uniq,
        skipped_image_files: skipped_image_files.uniq,
        failed_image_urls: failed_image_urls,
        sqlite_database_file: sqlite_store.database_file
      )
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

    def load_url_manifest
      sqlite_store.load_url_manifest
    end

    def load_pins_manifest
      sqlite_store.load_pins_manifest
    end

    def add_image_urls(url_manifest, image_urls)
      existing = url_manifest.fetch("image_original_urls")
      new_urls = image_urls - existing
      merged = (existing + new_urls).uniq.sort
      url_manifest["urls"] = merged
      url_manifest["image_original_urls"] = merged
      new_urls
    end

    def add_pins(pins_manifest, pin_urls)
      known_pin_urls = pins_manifest.fetch("pins").map { |pin| pin.fetch("pin_url") }
      pin_urls.each do |pin_url|
        next if known_pin_urls.include?(pin_url)

        pins_manifest.fetch("pins") << { "pin_url" => pin_url, "processed" => false, "interrupted" => false }
        known_pin_urls << pin_url
      end
      pins_manifest["pins"] = unique_pins(pins_manifest.fetch("pins"))
    end

    def add_seed_pin(pins_manifest, pin_url)
      return if pins_manifest.fetch("pins").any? { |pin| pin.fetch("pin_url") == pin_url }

      pins_manifest.fetch("pins") << { "pin_url" => pin_url, "processed" => false, "interrupted" => false }
    end

    def new_pin_urls(pins_manifest, pending_pin_urls, pin_urls)
      known_pin_urls = pins_manifest.fetch("pins").map { |pin| pin.fetch("pin_url") }
      pin_urls.reject { |pin_url| known_pin_urls.include?(pin_url) || pending_pin_urls.include?(pin_url) }
    end

    def mark_pin_processed(pins_manifest, pin_url)
      pins_manifest.fetch("pins").each do |pin|
        next unless pin.fetch("pin_url") == pin_url

        pin["processed"] = true
        pin["interrupted"] = false
      end
    end

    def mark_pin_interrupted(pins_manifest, pin_url)
      pins_manifest.fetch("pins").each do |pin|
        next unless pin.fetch("pin_url") == pin_url

        pin["processed"] = false
        pin["interrupted"] = true
      end
    end

    def next_unprocessed_pin(pins_manifest)
      pins_manifest.fetch("pins").find { |pin| !pin["processed"] && pin["interrupted"] } ||
        pins_manifest.fetch("pins").find { |pin| !pin["processed"] }
    end

    def unique_pins(pins)
      pins.each_with_object({}) do |pin, unique|
        pin_url = pin.fetch("pin_url")
        unique[pin_url] ||= { "pin_url" => pin_url, "processed" => false, "interrupted" => false }
        unique[pin_url]["processed"] ||= !!pin["processed"]
        unique[pin_url]["interrupted"] ||= !!pin["interrupted"]
        unique[pin_url]["interrupted"] = false if unique[pin_url]["processed"]
      end.values
    end

    def write_state(url_manifest, pins_manifest)
      sqlite_store.write_state(url_manifest: url_manifest, pins_manifest: pins_manifest)
    end
  end
end
