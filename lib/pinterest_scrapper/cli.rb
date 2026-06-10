# frozen_string_literal: true

require "uri"

require_relative "app"
require_relative "sqlite_store"

module PinterestScrapper
  class CLI
    SUCCESS = 0
    ERROR = 1

    def initialize(argv, stdout: $stdout, stderr: $stderr, stdin: $stdin, app_factory: nil, random: Random.new)
      @argv = argv
      @stdout = stdout
      @stderr = stderr
      @stdin = stdin
      @random = random
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

        write_stdout "Target folder: #{result.target_folder}"
        write_stdout "Pinterest URL: #{result.pinterest_url}"
        write_stdout "Pin URL: #{result.pin_url}"
        write_stdout "Pin URLs: #{result_count(result, :pin_url_count, :pin_urls)}"
        write_stdout "Image original URLs: #{result_count(result, :image_original_url_count, :image_original_urls)}"
        write_stdout "Saved images: #{result.saved_image_files.length}"
        write_stdout "Skipped images: #{result.skipped_image_files.length}"
        write_stdout "Failed images: #{result.failed_image_urls.length}"
        write_stdout "SQLite database: #{result.sqlite_database_file}"
      end

      SUCCESS
    rescue Interrupt
      request_stop
      write_stdout "Interrupt received. Ending gracefully..."

      SUCCESS
    rescue ArgumentError => e
      write_stderr "Error: #{e.message}"
      write_stderr usage

      ERROR
    rescue StandardError => e
      write_stderr "Error: #{e.message}"

      ERROR
    end

    private

    attr_reader :argv, :stdout, :stderr, :stdin, :app_factory, :random

    def result_count(result, count_method, collection_method)
      if result.respond_to?(count_method) && !result.public_send(count_method).nil?
        result.public_send(count_method)
      else
        result.public_send(collection_method).length
      end
    end

    def with_interrupt_handler
      previous_handler = nil
      trap_installed = false

      begin
        previous_handler = Signal.trap("INT") do
          request_stop
          write_stdout "Interrupt received. Ending gracefully after the current step..."
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
      write_stdout message
    end

    def write_stdout(message)
      stdout.puts timestamped_message(message)
      stdout.flush
    end

    def write_stderr(message)
      stderr.puts timestamped_message(message)
      stderr.flush
    end

    def write_prompt(message)
      stdout.print timestamped_message(message)
      stdout.flush
    end

    def timestamped_message(message)
      text = message.to_s
      return text if text.match?(/\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]/)

      "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] #{text}"
    end

    def parse_arguments
      unless [1, 2].include?(argv.length)
        raise ArgumentError, "expected 1 or 2 parameters, got #{argv.length}"
      end

      target_folder = argv[0]
      raw_pinterest_url = argv[1] || database_pin_url(target_folder) || prompt_for_pinterest_url
      pinterest_url = parse_pinterest_url(raw_pinterest_url)

      [target_folder, pinterest_url]
    end

    def database_pin_url(target_folder)
      store = SQLiteStore.new(target_folder: target_folder)
      interrupted_pin_url = store.next_interrupted_pin_url
      return interrupted_pin_url if interrupted_pin_url

      cursor = store.random_unprocessed_pin_cursor
      cursor.next_pin_url
    ensure
      cursor&.close
    end

    def prompt_for_pinterest_url
      write_prompt "Pinterest URL: "
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
