# frozen_string_literal: true

require "uri"

require_relative "app"

module PinterestScrapper
  class CLI
    SUCCESS = 0
    ERROR = 1

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv
      @stdout = stdout
      @stderr = stderr
    end

    def call
      target_folder, pinterest_url = parse_arguments
      result = App.new(target_folder: target_folder, pinterest_url: pinterest_url).run

      stdout.puts "Target folder: #{result.target_folder}"
      stdout.puts "Pinterest URL: #{result.pinterest_url}"

      SUCCESS
    rescue ArgumentError => e
      stderr.puts "Error: #{e.message}"
      stderr.puts usage

      ERROR
    end

    private

    attr_reader :argv, :stdout, :stderr

    def parse_arguments
      raise ArgumentError, "expected 2 parameters, got #{argv.length}" unless argv.length == 2

      target_folder = argv[0]
      pinterest_url = parse_pinterest_url(argv[1])

      [target_folder, pinterest_url]
    end

    def parse_pinterest_url(raw_url)
      uri = URI.parse(raw_url)

      unless %w[http https].include?(uri.scheme)
        raise ArgumentError, "Pinterest URL must start with http:// or https://"
      end

      unless pinterest_host?(uri.host)
        raise ArgumentError, "URL must be from pinterest.com"
      end

      uri
    rescue URI::InvalidURIError
      raise ArgumentError, "Pinterest URL is invalid"
    end

    def pinterest_host?(host)
      return false if host.nil?

      host == "pinterest.com" || host.end_with?(".pinterest.com")
    end

    def usage
      "Usage: ruby bin/pinterest_scrapper TARGET_FOLDER PINTEREST_URL"
    end
  end
end
