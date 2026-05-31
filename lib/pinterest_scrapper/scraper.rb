# frozen_string_literal: true

require "cgi"
require "json"
require "set"
require "uri"

module PinterestScrapper
  class Scraper
    Result = Struct.new(:pin_url, :image_original_urls, keyword_init: true)

    PIN_URL_PATTERN = %r{https?://(?:[a-z0-9-]+\.)?pinterest\.com/pin/\d+/?}i
    IMAGE_URL_PATTERN = %r{https?:\\?/\\?/i\.pinimg\.com/[^"'<>\s,)\\]+}i

    def initialize(html, source_url:)
      @html = html
      @source_url = source_url
    end

    def scrape
      Result.new(
        pin_url: collect_pin_url,
        image_original_urls: collect_image_original_urls
      )
    end

    private

    attr_reader :html, :source_url

    def collect_pin_url
      canonical_pin_url || source_url.to_s
    end

    def canonical_pin_url
      html.scan(PIN_URL_PATTERN).first
    end

    def collect_image_original_urls
      urls = Set.new

      html.scan(IMAGE_URL_PATTERN).each do |raw_url|
        normalized_url = normalize_image_url(raw_url)
        urls << normalized_url if normalized_url
      end

      urls.to_a.sort
    end

    def normalize_image_url(raw_url)
      url = CGI.unescapeHTML(raw_url).gsub("\\/", "/").gsub("\\u002F", "/")
      uri = URI.parse(url)
      return nil unless uri.host == "i.pinimg.com"

      uri.path = uri.path.sub(%r{/(?:\d+x|originals)/}, "/originals/")
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end
  end
end
