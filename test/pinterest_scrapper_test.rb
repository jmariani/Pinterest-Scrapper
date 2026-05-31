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
    :pin_urls,
    :urls,
    :image_original_urls,
    :saved_image_files,
    :skipped_image_files,
    :failed_image_urls,
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
      assert_includes stdout.string, "Pin URLs: 1"
      assert_includes stdout.string, "Image original URLs: 1"
      assert_includes stdout.string, "Saved images: 1"
      assert_includes stdout.string, "Skipped images: 0"
      assert_includes stdout.string, "Failed images: 0"
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
        fallback only
      HTML
      safari_snapshot = Struct.new(:body, :urls) do
        def capture(url, progress: nil)
          progress&.call("scroll 1: 1 original image URLs, 1 pin URLs, stable 0/3")
          PinterestScrapper::SafariSnapshot::Snapshot.new(url: url.to_s, body: body, urls: urls)
        end
      end
      safari_body = <<~HTML
        <link rel="canonical" href="https://www.pinterest.com/pin/123456789/">
        <img src="https://i.pinimg.com/736x/ab/cd/ef/abcdef.jpg">
        {"pin":"\/pin\/987654321\/","image":"https:\/\/i.pinimg.com\/564x\/aa\/bb\/cc\/aabbcc.jpg"}
        {"original":"https:\/\/i.pinimg.com\/originals\/11\/22\/33\/112233.jpg"}
        <img src="https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg?raw=1">
        <img srcset="https://i.pinimg.com/736x/44/55/66/445566.jpg 1x, https://i.pinimg.com/originals/22/33/44/223344.jpg 2x">
        <picture>
          <source srcset="https://i.pinimg.com/originals/33/44/55/334455.jpg 736w, https://i.pinimg.com/564x/66/77/88/667788.jpg 564w">
        </picture>
        <img alt="This contains an image of: WATCH NOW▶️🔞 10M+ Monthly Views" class="iFOUS5" draggable="true" fetchpriority="auto" loading="auto" elementtiming="grid-non-story-pin-image-related_pins" srcset="https://i.pinimg.com/236x/00/c5/ca/00c5caec39417c90e888c676a7ea8df5.jpg 1x, https://i.pinimg.com/474x/00/c5/ca/00c5caec39417c90e888c676a7ea8df5.jpg 2x, https://i.pinimg.com/736x/00/c5/ca/00c5caec39417c90e888c676a7ea8df5.jpg 3x, https://i.pinimg.com/originals/00/c5/ca/00c5caec39417c90e888c676a7ea8df5.jpg 4x" src="https://i.pinimg.com/236x/00/c5/ca/00c5caec39417c90e888c676a7ea8df5.jpg">
        <div data-image="//i.pinimg.com/originals/44/55/66/445566.jpg"></div>
        <div data-image="https%3A%2F%2Fi.pinimg.com%2Foriginals%2F55%2F66%2F77%2F556677.jpg"></div>
        {"original":"https:\\u002f\\u002fi.pinimg.com\\u002foriginals\\u002f66\\u002f77\\u002f88\\u002f667788.jpg"}
        {"pin":"https:\/\/www.pinterest.com\/pin\/555555555\/"}
        <a href="/ideas/outfits/">Ideas</a>
        <script src="//assets.pinterest.com/js/app.js"></script>
        <a href="https://help.pinterest.com/en">Help</a>
      HTML
      safari_snapshot = safari_snapshot.new(
        safari_body,
        [
          "https://i.pinimg.com/originals/dd/ee/ff/ddeeff.jpg",
          "https://www.pinterest.com/pin/777777777/"
        ]
      )
      image_downloader = Struct.new(:saved_files, :failed_urls, :downloaded_urls) do
        def download_all(urls, target_folder, progress: nil)
          downloaded_urls.concat(urls)
          saved_files.each_with_index do |path, index|
            File.binwrite(path, "image")
            progress&.call("Saved image #{index + 1}/#{urls.length}: #{File.basename(path)}")
          end
          PinterestScrapper::ImageDownloader::Result.new(
            saved_files: saved_files,
            skipped_files: [],
            failed_urls: failed_urls
          )
        end
      end
      saved_image_files = [
        File.join(dir, "00c5caec39417c90e888c676a7ea8df5.jpg"),
        File.join(dir, "112233.jpg"),
        File.join(dir, "223344.jpg"),
        File.join(dir, "334455.jpg"),
        File.join(dir, "445566.jpg"),
        File.join(dir, "556677.jpg"),
        File.join(dir, "667788.jpg"),
        File.join(dir, "abcdef.jpg"),
        File.join(dir, "ddeeff.jpg")
      ]
      downloaded_urls = []
      image_downloader = image_downloader.new(saved_image_files, [], downloaded_urls)

      progress_messages = []
      result = PinterestScrapper::App.new(
        target_folder: dir,
        pinterest_url: URI.parse("https://www.pinterest.com/pin/123456789/"),
        browser_opener: browser_opener,
        page_fetcher: page_fetcher,
        safari_snapshot: safari_snapshot,
        image_downloader: image_downloader,
        progress: ->(message) { progress_messages << message }
      ).run

      assert_empty opened_urls
      assert_includes progress_messages, "Opening Safari and collecting rendered page URLs..."
      assert_includes progress_messages, "scroll 1: 1 original image URLs, 1 pin URLs, stable 0/3"
      assert_includes progress_messages, "Collected 9 original image URLs and 4 pin URLs."
      assert_includes progress_messages, "Downloading 9 original images..."
      refute_includes progress_messages, "Downloading image 1/9: 00c5caec39417c90e888c676a7ea8df5.jpg"
      assert_includes progress_messages, "Saved image 9/9: ddeeff.jpg"
      assert_includes progress_messages, "Saved 9 images. Skipped 0. Failed 0."
      assert_equal "https://www.pinterest.com/pin/123456789/", result.pin_url
      assert_equal [
        "https://www.pinterest.com/pin/123456789/",
        "https://www.pinterest.com/pin/555555555/",
        "https://www.pinterest.com/pin/777777777/",
        "https://www.pinterest.com/pin/987654321/"
      ], result.pin_urls
      assert_equal [
        "https://i.pinimg.com/originals/00/c5/ca/00c5caec39417c90e888c676a7ea8df5.jpg",
        "https://i.pinimg.com/originals/11/22/33/112233.jpg",
        "https://i.pinimg.com/originals/22/33/44/223344.jpg",
        "https://i.pinimg.com/originals/33/44/55/334455.jpg",
        "https://i.pinimg.com/originals/44/55/66/445566.jpg",
        "https://i.pinimg.com/originals/55/66/77/556677.jpg",
        "https://i.pinimg.com/originals/66/77/88/667788.jpg",
        "https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg",
        "https://i.pinimg.com/originals/dd/ee/ff/ddeeff.jpg"
      ], result.image_original_urls
      assert_equal result.image_original_urls, downloaded_urls
      assert_equal saved_image_files, result.saved_image_files
      assert_empty result.skipped_image_files
      assert_empty result.failed_image_urls
      saved_image_files.each { |path| assert File.exist?(path) }
      refute_includes result.urls, "https://www.pinterest.com/ideas/outfits/"
      refute_includes result.urls, "https://assets.pinterest.com/js/app.js"
      refute_includes result.urls, "https://help.pinterest.com/en"
      refute_includes result.urls, "https://i.pinimg.com/736x/ab/cd/ef/abcdef.jpg"
      refute_includes result.urls, "https://i.pinimg.com/736x/44/55/66/445566.jpg"
      refute_includes result.urls, "https://i.pinimg.com/564x/66/77/88/667788.jpg"
      refute_includes result.urls, "https://i.pinimg.com/564x/aa/bb/cc/aabbcc.jpg"
      refute_includes result.urls, "https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg?raw=1"
      assert_includes result.urls, "https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg"
      assert File.exist?(result.url_manifest_file)
      assert File.exist?(result.pins_manifest_file)
      assert_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg"
      assert_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/00/c5/ca/00c5caec39417c90e888c676a7ea8df5.jpg"
      refute_includes File.read(result.url_manifest_file), "https://i.pinimg.com/736x/ab/cd/ef/abcdef.jpg"
      refute_includes File.read(result.url_manifest_file), "https://www.pinterest.com/ideas/outfits/"
      assert_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/11/22/33/112233.jpg"
      assert_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/22/33/44/223344.jpg"
      assert_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/33/44/55/334455.jpg"
      assert_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/44/55/66/445566.jpg"
      assert_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/55/66/77/556677.jpg"
      assert_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/66/77/88/667788.jpg"
      assert_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/dd/ee/ff/ddeeff.jpg"
      refute_includes File.read(result.url_manifest_file), "https://i.pinimg.com/originals/aa/bb/cc/aabbcc.jpg"
      assert_includes File.read(result.pins_manifest_file), "https://www.pinterest.com/pin/123456789/"
      assert_includes File.read(result.pins_manifest_file), "https://www.pinterest.com/pin/777777777/"
      assert_includes File.read(result.pins_manifest_file), "https://www.pinterest.com/pin/987654321/"
    end
  end

  def test_image_downloader_replaces_existing_image_when_new_image_has_better_resolution
    Dir.mktmpdir do |dir|
      fetcher = lambda do |url|
        if url.include?("large")
          png_bytes(width: 200, height: 100, marker: "large")
        else
          png_bytes(width: 50, height: 50, marker: "small")
        end
      end
      downloader = PinterestScrapper::ImageDownloader.new(fetcher: fetcher)
      urls = [
        "https://i.pinimg.com/originals/small/photo.png",
        "https://i.pinimg.com/originals/large/photo.png"
      ]

      result = downloader.download_all(urls, dir)
      destination = File.join(dir, "photo.png")

      assert_equal [destination], result.saved_files
      assert_empty result.failed_urls
      assert_includes File.binread(destination), "large"
      refute File.exist?(File.join(dir, "photo_2.png"))
    end
  end

  def test_image_downloader_keeps_existing_image_when_new_image_has_lower_resolution
    Dir.mktmpdir do |dir|
      fetcher = lambda do |url|
        if url.include?("large")
          png_bytes(width: 200, height: 100, marker: "large")
        else
          png_bytes(width: 50, height: 50, marker: "small")
        end
      end
      downloader = PinterestScrapper::ImageDownloader.new(fetcher: fetcher)
      urls = [
        "https://i.pinimg.com/originals/large/photo.png",
        "https://i.pinimg.com/originals/small/photo.png"
      ]

      result = downloader.download_all(urls, dir)
      destination = File.join(dir, "photo.png")

      assert_equal [destination], result.saved_files
      assert_equal [destination], result.skipped_files
      assert_empty result.failed_urls
      assert_includes File.binread(destination), "large"
      refute File.exist?(File.join(dir, "photo_2.png"))
    end
  end

  def test_image_downloader_reports_skipped_image_progress
    Dir.mktmpdir do |dir|
      fetcher = lambda do |url|
        if url.include?("large")
          png_bytes(width: 200, height: 100, marker: "large")
        else
          png_bytes(width: 50, height: 50, marker: "small")
        end
      end
      downloader = PinterestScrapper::ImageDownloader.new(fetcher: fetcher)
      progress_messages = []
      urls = [
        "https://i.pinimg.com/originals/large/photo.png",
        "https://i.pinimg.com/originals/small/photo.png"
      ]

      downloader.download_all(urls, dir, progress: ->(message) { progress_messages << message })

      assert_includes progress_messages, "Saved image 1/2: photo.png"
      assert_includes progress_messages, "Skipped image 2/2: photo.png"
    end
  end

  private

  def png_bytes(width:, height:, marker:)
    "\x89PNG\r\n\x1A\n".b +
      [13].pack("N") +
      "IHDR" +
      [width, height].pack("NN") +
      "\x08\x02\x00\x00\x00".b +
      "fake-crc" +
      marker
  end

  def fake_app_factory(target_folder, pinterest_url)
    lambda do |_target_folder, _pinterest_url|
      FakeApp.new(
        result: FakeResult.new(
          target_folder: target_folder,
          pinterest_url: pinterest_url,
          pin_url: pinterest_url,
          pin_urls: [pinterest_url],
          urls: [pinterest_url],
          image_original_urls: ["https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg"],
          saved_image_files: [File.join(target_folder, "abcdef.jpg")],
          skipped_image_files: [],
          failed_image_urls: [],
          url_manifest_file: File.join(target_folder, "url_manifest.json"),
          pins_manifest_file: File.join(target_folder, "pins_manifest.json")
        )
      )
    end
  end
end
