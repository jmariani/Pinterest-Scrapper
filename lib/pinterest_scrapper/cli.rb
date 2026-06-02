# frozen_string_literal: true

require "json"
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
      @stop_requested = false
      @app_factory = app_factory || lambda do |target_folder, pinterest_url|
        App.new(
          target_folder: target_folder,
          pinterest_url: pinterest_url,
          progress: method(:report_progress),
          stop_requested: method(:stop_requested?)
        )
      end
    end

    def call
      with_interrupt_handler do
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
      end

      SUCCESS
    rescue Interrupt
      request_stop
      stdout.puts "Interrupt received. Ending gracefully..."

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

    def with_interrupt_handler
      previous_handler = nil
      trap_installed = false

      begin
        previous_handler = Signal.trap("INT") do
          request_stop
          stdout.puts "Interrupt received. Ending gracefully after the current step..."
          stdout.flush
        end
        trap_installed = true
      rescue ArgumentError
        trap_installed = false
      end

      yield
    ensure
      Signal.trap("INT", previous_handler) if trap_installed
    end

    def request_stop
      @stop_requested = true
    end

    def stop_requested?
      @stop_requested
    end

    def report_progress(message)
      stdout.puts message
      stdout.flush
    end

    def parse_arguments
      unless [1, 2].include?(argv.length)
        raise ArgumentError, "expected 1 or 2 parameters, got #{argv.length}"
      end

      target_folder = argv[0]
      raw_pinterest_url = argv[1] || first_unprocessed_pin_url(target_folder) || prompt_for_pinterest_url
      pinterest_url = parse_pinterest_url(raw_pinterest_url)

      [target_folder, pinterest_url]
    end

    def first_unprocessed_pin_url(target_folder)
      manifest_file = File.join(target_folder, "pins_manifest.json")
      return nil unless File.exist?(manifest_file)

      manifest = JSON.parse(File.read(manifest_file))
      pin = Array(manifest["pins"]).find do |entry|
        entry.is_a?(Hash) && entry["pin_url"].to_s != "" && !entry["processed"]
      end

      pin&.fetch("pin_url")
    rescue JSON::ParserError
      raise ArgumentError, "Pinterest URL missing and pins manifest is invalid: #{manifest_file}"
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
      "Usage: ruby bin/pinterest_scrapper TARGET_FOLDER [PINTEREST_URL]"
    end
  end
end
