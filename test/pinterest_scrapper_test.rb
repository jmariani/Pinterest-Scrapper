# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"

require_relative "../lib/pinterest_scrapper"

class PinterestScrapperTest < Minitest::Test
  FakeResult = Struct.new(
    :target_folder,
    :pinterest_url,
    :pin_url,
    :image_original_urls,
    :url_manifest_file,
    :pins_manifest_file,
    keyword_init: true
  )

  FakeApp = Struct.new(:result, keyword_init: true) do
    def run
      result
    end
  end

  def test_cli_accepts_target_folder_and_pinterest_url
    Dir.mktmpdir do |dir|
      target_folder = File.join(dir, "downloads")
      stdout = StringIO.new
      stderr = StringIO.new
      app_factory = fake_app_factory(target_folder, "https://www.pinterest.com/pin/123456789/")

      status = PinterestScrapper::CLI.new(
        [target_folder, "https://www.pinterest.com/pin/123456789/"],
        stdout: stdout,
        stderr: stderr,
        app_factory: app_factory
      ).call

      assert_equal 0, status
      assert_includes stdout.string, "Target folder: #{target_folder}"
      assert_includes stdout.string, "Pinterest URL: https://www.pinterest.com/pin/123456789/"
      assert_includes stdout.string, "Pin URL: https://www.pinterest.com/pin/123456789/"
      assert_includes stdout.string, "Image original URLs: 1"
      assert_includes stdout.string, "URL manifest: #{File.join(target_folder, "url_manifest.json")}"
      assert_includes stdout.string, "Pins manifest: #{File.join(target_folder, "pins_manifest.json")}"
      assert_empty stderr.string
    end
  end

  def test_cli_rejects_missing_parameters
    stdout = StringIO.new
    stderr = StringIO.new

    status = PinterestScrapper::CLI.new([], stdout: stdout, stderr: stderr).call

    assert_equal 1, status
    assert_empty stdout.string
    assert_includes stderr.string, "expected 1 or 2 parameters, got 0"
  end

  def test_cli_asks_for_pinterest_url_when_second_parameter_is_missing
    Dir.mktmpdir do |dir|
      target_folder = File.join(dir, "downloads")
      stdout = StringIO.new
      stderr = StringIO.new
      stdin = StringIO.new("https://www.pinterest.com/pin/123456789/\n")
      app_factory = fake_app_factory(target_folder, "https://www.pinterest.com/pin/123456789/")

      status = PinterestScrapper::CLI.new(
        [target_folder],
        stdout: stdout,
        stderr: stderr,
        stdin: stdin,
        app_factory: app_factory
      ).call

      assert_equal 0, status
      assert_includes stdout.string, "Pinterest URL: "
      assert_includes stdout.string, "Target folder: #{target_folder}"
      assert_includes stdout.string, "Pinterest URL: https://www.pinterest.com/pin/123456789/"
      assert_empty stderr.string
    end
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

  def test_app_opens_safari_collects_urls_and_writes_output
    Dir.mktmpdir do |dir|
      opened_urls = []
      browser_opener = Struct.new(:opened_urls) do
        def open(url)
          opened_urls << url.to_s
        end
      end.new(opened_urls)
      page_fetcher = Struct.new(:body) do
        def fetch(url)
          PinterestScrapper::PageFetcher::Page.new(url: url.to_s, body: body)
        end
      end.new(<<~HTML)
        <link rel="canonical" href="https://www.pinterest.com/pin/123456789/">
        <img src="https://i.pinimg.com/736x/ab/cd/ef/abcdef.jpg">
      HTML

      result = PinterestScrapper::App.new(
        target_folder: dir,
        pinterest_url: URI.parse("https://www.pinterest.com/pin/123456789/"),
        browser_opener: browser_opener,
        page_fetcher: page_fetcher
      ).run

      assert_equal ["https://www.pinterest.com/pin/123456789/"], opened_urls
      assert_equal "https://www.pinterest.com/pin/123456789/", result.pin_url
      assert_equal ["https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg"], result.image_original_urls
      assert File.exist?(result.url_manifest_file)
      assert File.exist?(result.pins_manifest_file)
      assert_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg"
      assert_includes File.read(result.pins_manifest_file), "https://www.pinterest.com/pin/123456789/"
    end
  end

  private

  def fake_app_factory(target_folder, pinterest_url)
    lambda do |_target_folder, _pinterest_url|
      FakeApp.new(
        result: FakeResult.new(
          target_folder: target_folder,
          pinterest_url: pinterest_url,
          pin_url: pinterest_url,
          image_original_urls: ["https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg"],
          url_manifest_file: File.join(target_folder, "url_manifest.json"),
          pins_manifest_file: File.join(target_folder, "pins_manifest.json")
        )
      )
    end
  end
end
