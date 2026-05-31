# frozen_string_literal: true

require "cgi"
require "json"
require "set"
require "uri"

module PinterestScrapper
  class Scraper
    Result = Struct.new(:pin_url, :pin_urls, :urls, :image_original_urls, keyword_init: true)

    PIN_URL_PATTERN = %r{(?:https?:)?//(?:[a-z0-9-]+\.)?pinterest\.com/pin/\d+/?|/pin/\d+/?}i
    IMAGE_URL_PATTERN = %r{(?:https?:)?//i\.pinimg\.com/[^"'<>\s,)\\]+}i
    SRCSET_PATTERN = /srcset\s*=\s*(["'])(.*?)\1/im

    def initialize(html, source_url:, extra_urls: [])
      @html = html
      @source_url = source_url
      @extra_urls = extra_urls
      @normalized_html = normalize_text(html)
    end

    def scrape
      pin_urls = collect_pin_urls
      image_original_urls = collect_image_original_urls

      Result.new(
        pin_url: pin_urls.first || source_url.to_s,
        pin_urls: pin_urls,
        urls: image_original_urls,
        image_original_urls: image_original_urls
      )
    end

    private

    attr_reader :html, :source_url, :extra_urls, :normalized_html

    def collect_pin_urls
      urls = Set.new
      source_pin_url = normalize_pin_url(source_url.to_s)
      urls << source_pin_url if source_pin_url

      normalized_html.scan(PIN_URL_PATTERN).each do |raw_url|
        normalized_url = normalize_pin_url(raw_url)
        urls << normalized_url if normalized_url
      end
      extra_urls.each do |raw_url|
        normalized_url = normalize_pin_url(raw_url)
        urls << normalized_url if normalized_url
      end

      urls.to_a.sort
    end

    def collect_image_original_urls
      urls = Set.new

      normalized_html.scan(IMAGE_URL_PATTERN).each do |raw_url|
        normalized_url = normalize_image_url(raw_url)
        urls << normalized_url if normalized_url
      end
      normalized_html.scan(SRCSET_PATTERN).each do |_quote, srcset|
        srcset_image_urls(srcset).each { |url| urls << url }
      end
      extra_urls.each do |raw_url|
        normalized_url = normalize_image_url(raw_url)
        urls << normalized_url if normalized_url
      end

      urls.to_a.sort
    end

    def srcset_image_urls(srcset)
      normalize_text(srcset).split(",").filter_map do |entry|
        raw_url = entry.strip.split(/\s+/).first
        normalize_image_url(raw_url) if raw_url
      end
    end

    def normalize_text(text)
      decoded_text = CGI.unescapeHTML(text.to_s)
      decoded_text = percent_decode(decoded_text)

      decoded_text
        .gsub("\\/", "/")
        .gsub("\\u002F", "/")
        .gsub("\\u002f", "/")
        .gsub("\\u003A", ":")
        .gsub("\\u003a", ":")
        .gsub("\\u0026", "&")
    end

    def normalize_pin_url(raw_url)
      raw_url = normalize_text(raw_url)
      uri = URI.parse(raw_url)

      if uri.relative?
        uri = URI.join(source_url.to_s, uri)
      elsif uri.scheme.nil? && raw_url.start_with?("//")
        uri = URI.parse("https:#{raw_url}")
      end

      return nil unless uri.host == "pinterest.com" || uri.host&.end_with?(".pinterest.com")
      return nil unless uri.path.match?(%r{\A/pin/\d+/?\z})

      uri.scheme = "https"
      uri.host = "www.pinterest.com"
      uri.path = "#{uri.path.chomp("/")}/"
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def normalize_image_url(raw_url)
      url = normalize_text(raw_url)
      uri = URI.parse(url)
      uri = URI.parse("https:#{url}") if uri.scheme.nil? && url.start_with?("//")
      return nil unless uri.host == "i.pinimg.com"
      return nil unless uri.path.start_with?("/originals/")

      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def percent_decode(text)
      CGI.unescape(text)
    rescue ArgumentError
      text
    end
  end
end
