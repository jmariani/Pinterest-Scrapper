# frozen_string_literal: true

require "fileutils"
require "net/http"
require "thread"
require "uri"

module PinterestScrapper
  class ImageDownloader
    Result = Struct.new(:saved_files, :skipped_files, :failed_urls, keyword_init: true)

    DEFAULT_WORKERS = 10
    MAX_REDIRECTS = 5

    def initialize(fetcher: nil, workers: DEFAULT_WORKERS)
      @fetcher = fetcher
      @workers = workers
    end

    def download_all(urls, target_folder, progress: nil, stop_requested: nil)
      FileUtils.mkdir_p(target_folder)
      saved_files = []
      skipped_files = []
      failed_urls = []
      results_mutex = Mutex.new
      destination_mutexes = Hash.new { |hash, key| hash[key] = Mutex.new }
      destination_mutexes_mutex = Mutex.new
      jobs = Queue.new

      urls.each_with_index { |url, index| jobs << [url, index] }

      worker_count(urls).times.map do
        Thread.new do
          loop do
            url, index = jobs.pop(true)
            break if stop_requested&.call

            destination = destination_path(url, target_folder, index)
            destination_mutex = destination_mutexes_mutex.synchronize { destination_mutexes[destination] }
            image_body = download(url)
            action = destination_mutex.synchronize { keep_best_image(image_body, destination) }
            expanded_destination = File.expand_path(destination)

            results_mutex.synchronize do
              if action == :skipped
                skipped_files << expanded_destination
                progress&.call("Skipped image #{index + 1}/#{urls.length}: #{File.basename(destination)}")
              else
                saved_files << expanded_destination
                progress&.call("#{download_progress_action(action)} image #{index + 1}/#{urls.length}: #{File.basename(destination)}")
              end
            end
          rescue ThreadError
            break
          rescue StandardError => e
            results_mutex.synchronize do
              failed_urls << url
              progress&.call("Failed image #{index + 1}/#{urls.length}: #{File.basename(destination)} (#{e.message})")
            end
          end
        end
      end.each(&:join)

      progress&.call("Stop requested. Ending downloads gracefully.") if stop_requested&.call

      Result.new(saved_files: saved_files.uniq, skipped_files: skipped_files.uniq, failed_urls: failed_urls)
    end

    private

    attr_reader :fetcher, :workers

    def worker_count(urls)
      [[workers.to_i, 1].max, urls.length].min
    end

    def download(url, redirect_count: 0)
      return fetcher.call(url) if fetcher

      raise "too many redirects" if redirect_count > MAX_REDIRECTS

      uri = URI.parse(url.to_s)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Mozilla/5.0"
        http.request(request)
      end

      if response.is_a?(Net::HTTPRedirection)
        redirected_url = URI.join(uri, response.fetch("location")).to_s
        return download(redirected_url, redirect_count: redirect_count + 1)
      end

      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    def destination_path(url, target_folder, index)
      uri = URI.parse(url.to_s)
      basename = File.basename(uri.path)
      basename = "image_#{index + 1}" if basename.nil? || basename.empty? || basename == "/"

      structured_destination_path(target_folder, basename)
    rescue URI::InvalidURIError
      structured_destination_path(target_folder, "image_#{index + 1}")
    end

    def keep_best_image(image_body, destination)
      FileUtils.mkdir_p(File.dirname(destination))

      unless File.exist?(destination)
        File.binwrite(destination, image_body)
        return :saved
      end

      existing_resolution = image_resolution(File.binread(destination))
      new_resolution = image_resolution(image_body)

      if resolution_score(new_resolution) > resolution_score(existing_resolution)
        File.binwrite(destination, image_body)
        :replaced
      else
        :skipped
      end
    end

    def download_progress_action(action)
      action == :replaced ? "Replaced" : "Saved"
    end

    def structured_destination_path(target_folder, basename)
      normalized_name = basename.to_s
      first_level = folder_segment(normalized_name[0, 2])
      second_level = folder_segment(normalized_name[2, 2])

      File.join(target_folder, first_level, second_level, normalized_name)
    end

    def folder_segment(segment)
      segment.to_s.downcase.ljust(2, "_")
    end

    def resolution_score(resolution)
      width, height = resolution
      width.to_i * height.to_i
    end

    def image_resolution(bytes)
      png_resolution(bytes) ||
        jpeg_resolution(bytes) ||
        gif_resolution(bytes) ||
        webp_resolution(bytes) ||
        [0, 0]
    end

    def png_resolution(bytes)
      return nil unless bytes.start_with?("\x89PNG\r\n\x1A\n".b)
      return nil unless bytes.bytesize >= 24

      [bytes.byteslice(16, 4).unpack1("N"), bytes.byteslice(20, 4).unpack1("N")]
    end

    def jpeg_resolution(bytes)
      return nil unless bytes.byteslice(0, 2) == "\xFF\xD8".b

      index = 2
      while index < bytes.bytesize
        index += 1 while bytes.getbyte(index) == 0xFF
        marker = bytes.getbyte(index)
        index += 1
        next if marker.nil? || marker == 0xD8 || marker == 0xD9

        length = bytes.byteslice(index, 2)&.unpack1("n")
        return nil unless length && length >= 2

        if [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].include?(marker)
          height = bytes.byteslice(index + 3, 2)&.unpack1("n")
          width = bytes.byteslice(index + 5, 2)&.unpack1("n")
          return [width, height] if width && height
        end

        index += length
      end

      nil
    end

    def gif_resolution(bytes)
      return nil unless bytes.start_with?("GIF87a") || bytes.start_with?("GIF89a")
      return nil unless bytes.bytesize >= 10

      [bytes.byteslice(6, 2).unpack1("v"), bytes.byteslice(8, 2).unpack1("v")]
    end

    def webp_resolution(bytes)
      return nil unless bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WEBP"

      if bytes.byteslice(12, 4) == "VP8X" && bytes.bytesize >= 30
        width = bytes.byteslice(24, 3).bytes.each_with_index.sum { |byte, shift| byte << (8 * shift) } + 1
        height = bytes.byteslice(27, 3).bytes.each_with_index.sum { |byte, shift| byte << (8 * shift) } + 1
        return [width, height]
      end

      nil
    end
  end
end
