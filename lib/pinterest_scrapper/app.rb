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

      scraped_page = scrape_page
      manifest_files = write_manifests(scraped_page)
      download_result = download_images(scraped_page.image_original_urls)

      Result.new(
        target_folder: File.expand_path(target_folder),
        pinterest_url: pinterest_url.to_s,
        pin_url: scraped_page.pin_url,
        pin_urls: scraped_page.pin_urls,
        urls: scraped_page.urls,
        image_original_urls: scraped_page.image_original_urls,
        saved_image_files: download_result.saved_files,
        skipped_image_files: download_result.skipped_files,
        failed_image_urls: download_result.failed_urls,
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

    def scrape_page
      report_progress "Opening Safari and collecting rendered page URLs..."
      snapshot = safari_snapshot.capture(pinterest_url, progress: progress)
      scraped_page = Scraper.new(snapshot.body, source_url: snapshot.url, extra_urls: snapshot.urls).scrape
      report_progress "Collected #{scraped_page.image_original_urls.length} original image URLs and #{scraped_page.pin_urls.length} pin URLs."
      scraped_page
    rescue StandardError => e
      report_progress "Safari collection failed: #{e.message}"
      report_progress "Falling back to the initial HTML response..."
      page = page_fetcher.fetch(pinterest_url)
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

    def write_manifests(scraped_page)
      url_manifest_file = File.join(target_folder, "url_manifest.json")
      pins_manifest_file = File.join(target_folder, "pins_manifest.json")

      url_manifest = {
        urls: scraped_page.urls,
        image_original_urls: scraped_page.image_original_urls
      }
      pins_manifest = {
        pins: scraped_page.pin_urls.map { |pin_url| { pin_url: pin_url } }
      }

      File.write(url_manifest_file, JSON.pretty_generate(url_manifest))
      File.write(pins_manifest_file, JSON.pretty_generate(pins_manifest))

      {
        url_manifest_file: File.expand_path(url_manifest_file),
        pins_manifest_file: File.expand_path(pins_manifest_file)
      }
    end
  end
end
