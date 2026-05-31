# frozen_string_literal: true

require "fileutils"
require "uri"

module PinterestScrapper
  class App
    Result = Struct.new(:target_folder, :pinterest_url, keyword_init: true)

    def initialize(target_folder:, pinterest_url:)
      @target_folder = target_folder
      @pinterest_url = pinterest_url
    end

    def run
      FileUtils.mkdir_p(target_folder)

      Result.new(
        target_folder: File.expand_path(target_folder),
        pinterest_url: pinterest_url.to_s
      )
    end

    private

    attr_reader :target_folder, :pinterest_url
  end
end
