# frozen_string_literal: true

require "fileutils"
require "json"
require "uri"

require_relative "browser_opener"
require_relative "page_fetcher"
require_relative "scraper"

module PinterestScrapper
  class App
    Result = Struct.new(
      :target_folder,
      :pinterest_url,
      :pin_url,
      :image_original_urls,
      :url_manifest_file,
      :pins_manifest_file,
      keyword_init: true
    )

    def initialize(
      target_folder:,
      pinterest_url:,
      browser_opener: BrowserOpener.new,
      page_fetcher: PageFetcher.new
    )
      @target_folder = target_folder
      @pinterest_url = pinterest_url
      @browser_opener = browser_opener
      @page_fetcher = page_fetcher
    end

    def run
      FileUtils.mkdir_p(target_folder)
      browser_opener.open(pinterest_url)

      page = page_fetcher.fetch(pinterest_url)
      scraped_page = Scraper.new(page.body, source_url: page.url).scrape
      manifest_files = write_manifests(scraped_page)

      Result.new(
        target_folder: File.expand_path(target_folder),
        pinterest_url: pinterest_url.to_s,
        pin_url: scraped_page.pin_url,
        image_original_urls: scraped_page.image_original_urls,
        url_manifest_file: manifest_files.fetch(:url_manifest_file),
        pins_manifest_file: manifest_files.fetch(:pins_manifest_file)
      )
    end

    private

    attr_reader :target_folder, :pinterest_url, :browser_opener, :page_fetcher

    def write_manifests(scraped_page)
      url_manifest_file = File.join(target_folder, "url_manifest.json")
      pins_manifest_file = File.join(target_folder, "pins_manifest.json")

      url_manifest = {
        image_original_urls: scraped_page.image_original_urls
      }
      pins_manifest = {
        pins: [
          {
            pin_url: scraped_page.pin_url,
            image_original_urls: scraped_page.image_original_urls
          }
        ]
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
