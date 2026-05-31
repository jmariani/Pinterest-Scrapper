# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"

require_relative "../lib/pinterest_scrapper"

class PinterestScrapperTest < Minitest::Test
  def test_cli_accepts_target_folder_and_pinterest_url
    Dir.mktmpdir do |dir|
      target_folder = File.join(dir, "downloads")
      stdout = StringIO.new
      stderr = StringIO.new

      status = PinterestScrapper::CLI.new(
        [target_folder, "https://www.pinterest.com/pin/123456789/"],
        stdout: stdout,
        stderr: stderr
      ).call

      assert_equal 0, status
      assert Dir.exist?(target_folder)
      assert_includes stdout.string, "Target folder: #{target_folder}"
      assert_includes stdout.string, "Pinterest URL: https://www.pinterest.com/pin/123456789/"
      assert_empty stderr.string
    end
  end

  def test_cli_rejects_missing_parameters
    stdout = StringIO.new
    stderr = StringIO.new

    status = PinterestScrapper::CLI.new([], stdout: stdout, stderr: stderr).call

    assert_equal 1, status
    assert_empty stdout.string
    assert_includes stderr.string, "expected 2 parameters, got 0"
  end

  def test_cli_rejects_non_pinterest_urls
    stdout = StringIO.new
    stderr = StringIO.new

    status = PinterestScrapper::CLI.new(
      ["downloads", "https://example.com/pin/123456789/"],
      stdout: stdout,
      stderr: stderr
    ).call

    assert_equal 1, status
    assert_empty stdout.string
    assert_includes stderr.string, "URL must be from pinterest.com"
  end
end
