# frozen_string_literal: true

require "net/http"
require "uri"

module PinterestScrapper
  class PageFetcher
    Page = Struct.new(:url, :body, keyword_init: true)

    USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " \
                 "AppleWebKit/605.1.15 (KHTML, like Gecko) " \
                 "Version/17.0 Safari/605.1.15"
    MAX_REDIRECTS = 5

    def fetch(url, redirect_count: 0)
      raise "too many redirects while fetching Pinterest page" if redirect_count > MAX_REDIRECTS

      uri = URI.parse(url.to_s)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = USER_AGENT
        request["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        http.request(request)
      end

      if response.is_a?(Net::HTTPRedirection)
        redirected_url = URI.join(uri, response.fetch("location")).to_s
        return fetch(redirected_url, redirect_count: redirect_count + 1)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "Pinterest returned HTTP #{response.code}"
      end

      Page.new(url: uri.to_s, body: response.body)
    end
  end
end
