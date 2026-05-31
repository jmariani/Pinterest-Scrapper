# frozen_string_literal: true

require "fileutils"
require "json"
require "uri"

require_relative "browser_opener"
require_relative "image_downloader"
require_relative "page_fetcher"
require_relative "safari_snapshot"
require_relative "scraper"

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
      :url_manifest_file,
      :pins_manifest_file,
      keyword_init: true
    )

    def initialize(
      target_folder:,
      pinterest_url:,
      browser_opener: BrowserOpener.new,
      page_fetcher: PageFetcher.new,
      safari_snapshot: SafariSnapshot.new,
      image_downloader: ImageDownloader.new,
      progress: nil
    )
      @target_folder = target_folder
      @pinterest_url = pinterest_url
      @browser_opener = browser_opener
      @page_fetcher = page_fetcher
      @safari_snapshot = safari_snapshot
      @image_downloader = image_downloader
      @progress = progress
    end

    def run
      FileUtils.mkdir_p(target_folder)
      url_manifest = load_url_manifest
      pins_manifest = load_pins_manifest
      saved_image_files = []
      skipped_image_files = []
      failed_image_urls = []
      last_scraped_page = nil
      next_url = pinterest_url.to_s

      loop do
        last_scraped_page = scrape_page(next_url)
        add_pins(pins_manifest, last_scraped_page.pin_urls)
        new_image_urls = add_image_urls(url_manifest, last_scraped_page.image_original_urls)
        write_manifests(url_manifest, pins_manifest)

        download_result = download_images(new_image_urls)
        saved_image_files.concat(download_result.saved_files)
        skipped_image_files.concat(download_result.skipped_files)
        failed_image_urls.concat(download_result.failed_urls)

        mark_pin_processed(pins_manifest, next_url)
        mark_pin_processed(pins_manifest, last_scraped_page.pin_url)
        write_manifests(url_manifest, pins_manifest)

        next_pin = next_unprocessed_pin(pins_manifest)
        break unless next_pin

        next_url = next_pin.fetch("pin_url")
        report_progress "Processing next pin: #{next_url}"
      end

      manifest_files = manifest_file_paths
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
        url_manifest_file: manifest_files.fetch(:url_manifest_file),
        pins_manifest_file: manifest_files.fetch(:pins_manifest_file)
      )
    end

    private

    attr_reader :target_folder,
                :pinterest_url,
                :browser_opener,
                :page_fetcher,
                :safari_snapshot,
                :image_downloader,
                :progress

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

    def download_images(image_urls)
      report_progress "Downloading #{image_urls.length} original images..."
      result = image_downloader.download_all(image_urls, target_folder, progress: progress)
      report_progress "Saved #{result.saved_files.length} images. Skipped #{result.skipped_files.length}. Failed #{result.failed_urls.length}."
      result
    end

    def load_url_manifest
      path = manifest_file_paths.fetch(:url_manifest_file)
      return { "urls" => [], "image_original_urls" => [] } unless File.exist?(path)

      manifest = JSON.parse(File.read(path))
      image_urls = Array(manifest["image_original_urls"] || manifest["urls"]).uniq.sort
      { "urls" => image_urls, "image_original_urls" => image_urls }
    rescue JSON::ParserError
      { "urls" => [], "image_original_urls" => [] }
    end

    def load_pins_manifest
      path = manifest_file_paths.fetch(:pins_manifest_file)
      return { "pins" => [] } unless File.exist?(path)

      manifest = JSON.parse(File.read(path))
      pins = Array(manifest["pins"]).filter_map do |pin|
        pin_url = pin.is_a?(Hash) ? pin["pin_url"] : pin.to_s
        next if pin_url.nil? || pin_url.empty?

        { "pin_url" => pin_url, "processed" => pin.is_a?(Hash) ? !!pin["processed"] : false }
      end

      { "pins" => unique_pins(pins) }
    rescue JSON::ParserError
      { "pins" => [] }
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

        pins_manifest.fetch("pins") << { "pin_url" => pin_url, "processed" => false }
        known_pin_urls << pin_url
      end
      pins_manifest["pins"] = unique_pins(pins_manifest.fetch("pins"))
    end

    def mark_pin_processed(pins_manifest, pin_url)
      pins_manifest.fetch("pins").each do |pin|
        pin["processed"] = true if pin.fetch("pin_url") == pin_url
      end
    end

    def next_unprocessed_pin(pins_manifest)
      pins_manifest.fetch("pins").find { |pin| !pin["processed"] }
    end

    def unique_pins(pins)
      pins.each_with_object({}) do |pin, unique|
        pin_url = pin.fetch("pin_url")
        unique[pin_url] ||= { "pin_url" => pin_url, "processed" => false }
        unique[pin_url]["processed"] ||= !!pin["processed"]
      end.values
    end

    def manifest_file_paths
      {
        url_manifest_file: File.expand_path(File.join(target_folder, "url_manifest.json")),
        pins_manifest_file: File.expand_path(File.join(target_folder, "pins_manifest.json"))
      }
    end

    def write_manifests(url_manifest, pins_manifest)
      url_manifest_file = File.join(target_folder, "url_manifest.json")
      pins_manifest_file = File.join(target_folder, "pins_manifest.json")

      File.write(url_manifest_file, JSON.pretty_generate(url_manifest))
      File.write(pins_manifest_file, JSON.pretty_generate(pins_manifest))

      manifest_file_paths
    end
  end
end
