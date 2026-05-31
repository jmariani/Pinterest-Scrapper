# frozen_string_literal: true

require "uri"

require_relative "app"

module PinterestScrapper
  class CLI
    SUCCESS = 0
    ERROR = 1

    def initialize(argv, stdout: $stdout, stderr: $stderr, stdin: $stdin, app_factory: nil)
      @argv = argv
      @stdout = stdout
      @stderr = stderr
      @stdin = stdin
      @app_factory = app_factory || lambda do |target_folder, pinterest_url|
        App.new(
          target_folder: target_folder,
          pinterest_url: pinterest_url,
          progress: method(:report_progress)
        )
      end
    end

    def call
      target_folder, pinterest_url = parse_arguments
      result = app_factory.call(target_folder, pinterest_url).run

      stdout.puts "Target folder: #{result.target_folder}"
      stdout.puts "Pinterest URL: #{result.pinterest_url}"
      stdout.puts "Pin URL: #{result.pin_url}"
      stdout.puts "Pin URLs: #{result.pin_urls.length}"
      stdout.puts "Image original URLs: #{result.image_original_urls.length}"
      stdout.puts "Saved images: #{result.saved_image_files.length}"
      stdout.puts "Skipped images: #{result.skipped_image_files.length}"
      stdout.puts "Failed images: #{result.failed_image_urls.length}"
      stdout.puts "URL manifest: #{result.url_manifest_file}"
      stdout.puts "Pins manifest: #{result.pins_manifest_file}"

      SUCCESS
    rescue ArgumentError => e
      stderr.puts "Error: #{e.message}"
      stderr.puts usage

      ERROR
    rescue StandardError => e
      stderr.puts "Error: #{e.message}"

      ERROR
    end

    private

    attr_reader :argv, :stdout, :stderr, :stdin, :app_factory

    def report_progress(message)
      stdout.puts message
      stdout.flush
    end

    def parse_arguments
      unless [1, 2].include?(argv.length)
        raise ArgumentError, "expected 1 or 2 parameters, got #{argv.length}"
      end

      target_folder = argv[0]
      raw_pinterest_url = argv[1] || prompt_for_pinterest_url
      pinterest_url = parse_pinterest_url(raw_pinterest_url)

      [target_folder, pinterest_url]
    end

    def prompt_for_pinterest_url
      stdout.print "Pinterest URL: "
      stdin.gets&.strip.to_s
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
