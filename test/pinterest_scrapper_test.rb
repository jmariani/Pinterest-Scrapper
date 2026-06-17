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
    :pin_url_count,
    :urls,
    :image_original_urls,
    :image_original_url_count,
    :saved_image_files,
    :skipped_image_files,
    :failed_image_urls,
    :sqlite_database_file,
    :stopped_early,
    keyword_init: true
  )

  FakeApp = Struct.new(:result, keyword_init: true) do
    def run
      result
    end
  end

  FixedRandom = Struct.new(:value) do
    def rand(_limit)
      value
    end
  end

  FakePinCursor = Struct.new(:pin_urls) do
    attr_reader :closed

    def next_pin_url
      pin_urls.shift
    end

    def close
      @closed = true
    end

    def closed?
      !!closed
    end
  end

  FakeSQLiteStore = Struct.new(
    :image_urls,
    :pins,
    :written_image_url_batches,
    :written_pin_batches,
    keyword_init: true
  ) do
    def setup; end

    def database_file
      "/tmp/fake-pinterest-scrapper.sqlite3"
    end

    def load_image_urls
      image_urls
    end

    def image_url_count
      image_urls.length
    end

    def load_pins
      pins
    end

    def pin_count
      pins.length
    end

    def write_image_urls(urls, progress: nil)
      written_image_url_batches << urls
      inserted_urls = urls.reject { |url| image_urls.include?(url) }
      image_urls.concat(inserted_urls)
      inserted_urls
    end

    def write_pins(pins, progress: nil)
      written_pin_batches << pins
      inserted_count = 0
      pins.each do |pin|
        next if self.pins.any? { |existing_pin| existing_pin.fetch("pin_url") == pin.fetch("pin_url") }

        self.pins << {
          "pin_url" => pin.fetch("pin_url"),
          "processed" => !!pin["processed"],
          "interrupted" => !!pin["interrupted"]
        }
        inserted_count += 1
      end
      inserted_count
    end

    def write_interrupted_pins(pins)
      raise "pin cursor is still open" if @last_cursor && !@last_cursor.closed?

      written_pin_batches << pins
      pins.each do |pin|
        upsert_pin(pin.fetch("pin_url"), processed: false, interrupted: true)
      end
    end

    def write_processed_pins(pins)
      written_pin_batches << pins
      pins.each do |pin|
        upsert_pin(pin.fetch("pin_url"), processed: true, interrupted: false)
      end
    end

    def next_unprocessed_pin_url
      pin = pins.find { |entry| !entry["processed"] && entry["interrupted"] } ||
            pins.find { |entry| !entry["processed"] }
      pin&.fetch("pin_url")
    end

    def next_interrupted_pin_url
      pin = pins.find { |entry| !entry["processed"] && entry["interrupted"] }
      pin&.fetch("pin_url")
    end

    def random_unprocessed_pin_cursor
      @last_cursor = FakePinCursor.new(
        pins.reject { |entry| entry["processed"] || entry["interrupted"] }.map { |entry| entry.fetch("pin_url") }
      )
    end

    private

    def upsert_pin(pin_url, processed:, interrupted:)
      pin = pins.find { |entry| entry.fetch("pin_url") == pin_url }
      unless pin
        pin = { "pin_url" => pin_url }
        pins << pin
      end
      pin["processed"] = processed
      pin["interrupted"] = interrupted
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
      refute_includes stdout.string, "URL manifest:"
      refute_includes stdout.string, "Pins manifest:"
      assert_includes stdout.string, "SQLite database: #{File.join(target_folder, "pinterest_scrapper.sqlite3")}"
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
    assert_match(/\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] Error: /, stderr.string)
  end

  def test_cli_timestamps_stdout_stderr_and_prompts
    Dir.mktmpdir do |dir|
      target_folder = File.join(dir, "downloads")
      stdout = StringIO.new
      stderr = StringIO.new
      stdin = StringIO.new("https://www.pinterest.com/pin/222222222/\n")
      app_factory = fake_app_factory(target_folder, "https://www.pinterest.com/pin/222222222/")

      PinterestScrapper::CLI.new(
        [target_folder],
        stdout: stdout,
        stderr: stderr,
        stdin: stdin,
        app_factory: app_factory
      ).call
      PinterestScrapper::CLI.new(
        [],
        stdout: StringIO.new,
        stderr: stderr
      ).call

      stdout_lines = stdout.string.lines
      stderr_lines = stderr.string.lines

      assert stdout_lines.all? { |line| line.match?(/\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]/) }
      assert stderr_lines.all? { |line| line.match?(/\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]/) }
      assert_includes stdout.string, "] Pinterest URL: "
    end
  end

  def test_cli_uses_random_unprocessed_pin_when_second_parameter_is_missing
    Dir.mktmpdir do |dir|
      target_folder = File.join(dir, "downloads")
      PinterestScrapper::SQLiteStore.new(target_folder: target_folder).write_pins(
        [
          { "pin_url" => "https://www.pinterest.com/pin/111111111/", "processed" => true },
          { "pin_url" => "https://www.pinterest.com/pin/222222222/", "processed" => false },
          { "pin_url" => "https://www.pinterest.com/pin/333333333/", "processed" => false }
        ]
      )
      stdout = StringIO.new
      stderr = StringIO.new
      selected_urls = []
      app_factory = lambda do |_target_folder, pinterest_url|
        selected_urls << pinterest_url.to_s
        FakeApp.new(
          result: FakeResult.new(
            target_folder: target_folder,
            pinterest_url: pinterest_url.to_s,
            pin_url: pinterest_url.to_s,
            pin_urls: [pinterest_url.to_s],
            pin_url_count: 1,
            urls: [pinterest_url.to_s],
            image_original_urls: [],
            image_original_url_count: 0,
            saved_image_files: [],
            skipped_image_files: [],
            failed_image_urls: [],
            sqlite_database_file: File.join(target_folder, "pinterest_scrapper.sqlite3"),
            stopped_early: false
          )
        )
      end

      status = PinterestScrapper::CLI.new(
        [target_folder],
        stdout: stdout,
        stderr: stderr,
        app_factory: app_factory
      ).call

      assert_equal 0, status
      assert_includes stdout.string, "Target folder: #{target_folder}"
      assert_includes [
        "https://www.pinterest.com/pin/222222222/",
        "https://www.pinterest.com/pin/333333333/"
      ], selected_urls.fetch(0)
      assert_includes stdout.string, "Pinterest URL: #{selected_urls.fetch(0)}"
      assert_empty stderr.string
    end
  end

  def test_cli_uses_interrupted_pin_before_random_unprocessed_pin_when_second_parameter_is_missing
    Dir.mktmpdir do |dir|
      target_folder = File.join(dir, "downloads")
      PinterestScrapper::SQLiteStore.new(target_folder: target_folder).write_pins(
        [
          { "pin_url" => "https://www.pinterest.com/pin/111111111/", "processed" => false },
          { "pin_url" => "https://www.pinterest.com/pin/222222222/", "processed" => false, "interrupted" => true },
          { "pin_url" => "https://www.pinterest.com/pin/333333333/", "processed" => false }
        ]
      )
      stdout = StringIO.new
      stderr = StringIO.new
      app_factory = fake_app_factory(target_folder, "https://www.pinterest.com/pin/222222222/")

      status = PinterestScrapper::CLI.new(
        [target_folder],
        stdout: stdout,
        stderr: stderr,
        app_factory: app_factory,
        random: FixedRandom.new(2)
      ).call

      assert_equal 0, status
      assert_includes stdout.string, "Pinterest URL: https://www.pinterest.com/pin/222222222/"
      assert_empty stderr.string
    end
  end

  def test_cli_prompts_when_second_parameter_is_missing_and_no_unprocessed_pin_exists
    Dir.mktmpdir do |dir|
      target_folder = File.join(dir, "downloads")
      PinterestScrapper::SQLiteStore.new(target_folder: target_folder).write_pins(
        [{ "pin_url" => "https://www.pinterest.com/pin/111111111/", "processed" => true }]
      )
      stdout = StringIO.new
      stderr = StringIO.new
      stdin = StringIO.new("https://www.pinterest.com/pin/222222222/\n")
      app_factory = fake_app_factory(target_folder, "https://www.pinterest.com/pin/222222222/")

      status = PinterestScrapper::CLI.new(
        [target_folder],
        stdout: stdout,
        stderr: stderr,
        stdin: stdin,
        app_factory: app_factory
      ).call

      assert_equal 0, status
      assert_includes stdout.string, "Pinterest URL: "
      assert_includes stdout.string, "Pinterest URL: https://www.pinterest.com/pin/222222222/"
      assert_empty stderr.string
    end
  end

  def test_cli_prompts_when_second_parameter_is_missing_and_no_database_exists
    Dir.mktmpdir do |dir|
      target_folder = File.join(dir, "downloads")
      Dir.mkdir(target_folder)
      stdout = StringIO.new
      stderr = StringIO.new
      stdin = StringIO.new("https://www.pinterest.com/pin/222222222/\n")
      app_factory = fake_app_factory(target_folder, "https://www.pinterest.com/pin/222222222/")

      status = PinterestScrapper::CLI.new(
        [target_folder],
        stdout: stdout,
        stderr: stderr,
        stdin: stdin,
        app_factory: app_factory
      ).call

      assert_equal 0, status
      assert_includes stdout.string, "Pinterest URL: "
      assert_includes stdout.string, "Pinterest URL: https://www.pinterest.com/pin/222222222/"
      assert_empty stderr.string
    end
  end

  def test_cli_reports_counts_as_not_counted_after_stop
    Dir.mktmpdir do |dir|
      target_folder = File.join(dir, "downloads")
      stdout = StringIO.new
      stderr = StringIO.new
      app_factory = lambda do |_target_folder, pinterest_url|
        FakeApp.new(
          result: FakeResult.new(
            target_folder: target_folder,
            pinterest_url: pinterest_url.to_s,
            pin_url: pinterest_url.to_s,
            pin_urls: [],
            pin_url_count: nil,
            urls: [],
            image_original_urls: [],
            image_original_url_count: nil,
            saved_image_files: [],
            skipped_image_files: [],
            failed_image_urls: [],
            sqlite_database_file: File.join(target_folder, "pinterest_scrapper.sqlite3"),
            stopped_early: true
          )
        )
      end

      status = PinterestScrapper::CLI.new(
        [target_folder, "https://www.pinterest.com/pin/123456789/"],
        stdout: stdout,
        stderr: stderr,
        app_factory: app_factory
      ).call

      assert_equal 0, status
      assert_includes stdout.string, "Pin URLs: not counted after stop"
      assert_includes stdout.string, "Image original URLs: not counted after stop"
      assert_empty stderr.string
    end
  end

  def test_cli_uses_interrupted_pin_from_sqlite
    Dir.mktmpdir do |dir|
      target_folder = File.join(dir, "downloads")
      store = PinterestScrapper::SQLiteStore.new(target_folder: target_folder)
      store.write_pins(
        [
          { "pin_url" => "https://www.pinterest.com/pin/111111111/", "processed" => false, "interrupted" => false },
          { "pin_url" => "https://www.pinterest.com/pin/222222222/", "processed" => false, "interrupted" => true }
        ]
      )
      stdout = StringIO.new
      stderr = StringIO.new
      app_factory = fake_app_factory(target_folder, "https://www.pinterest.com/pin/222222222/")

      status = PinterestScrapper::CLI.new(
        [target_folder],
        stdout: stdout,
        stderr: stderr,
        app_factory: app_factory
      ).call

      assert_equal 0, status
      assert_includes stdout.string, "Pinterest URL: https://www.pinterest.com/pin/222222222/"
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

  def test_sqlite_store_creates_indexes
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      store.setup
      database = SQLite3::Database.new(store.database_file)
      indexes = database.execute("SELECT name FROM sqlite_master WHERE type = 'index'").flatten

      assert_includes indexes, "sqlite_autoindex_image_urls_1"
      assert_includes indexes, "sqlite_autoindex_pins_1"
      assert_includes indexes, "index_image_urls_url"
      assert_includes indexes, "index_image_urls_created_at"
      assert_includes indexes, "index_pins_processing_state"
      assert_includes indexes, "index_pins_updated_at"
    ensure
      database&.close
    end
  end

  def test_sqlite_store_random_pin_cursor_uses_rowid_scan_without_temp_sort
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      store.write_pins(
        10.times.map do |index|
          {
            "pin_url" => "https://www.pinterest.com/pin/#{index}/",
            "processed" => index.even?,
            "interrupted" => false
          }
        end
      )
      database = SQLite3::Database.new(store.database_file)
      plan = database.execute(<<~SQL, [5]).map { |row| row.fetch(3) }
        EXPLAIN QUERY PLAN
        SELECT pin_url
        FROM pins NOT INDEXED
        WHERE processed = 0
          AND interrupted = 0
          AND rowid >= ?
        ORDER BY rowid
      SQL

      assert plan.any? { |entry| entry.include?("INTEGER PRIMARY KEY") }
      refute plan.any? { |entry| entry.include?("USE TEMP B-TREE") }
      refute plan.any? { |entry| entry.include?("index_pins_processing_state") }
    ensure
      database&.close
    end
  end

  def test_sqlite_store_defaults_created_at_to_current_timestamp
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      store.write_image_urls(["https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg"])
      store.write_pins(
        [
          { "pin_url" => "https://www.pinterest.com/pin/123456789/", "processed" => false, "interrupted" => false }
        ]
      )
      database = SQLite3::Database.new(store.database_file)
      database.results_as_hash = true
      image_name_column = database.table_info("image_urls").find { |column| column.fetch("name") == "image_name" }
      image_created_at = database.get_first_value("SELECT created_at FROM image_urls")
      pin_created_at = database.get_first_value("SELECT created_at FROM pins")
      image_default = database.table_info("image_urls").find { |column| column.fetch("name") == "created_at" }.fetch("dflt_value")
      pin_default = database.table_info("pins").find { |column| column.fetch("name") == "created_at" }.fetch("dflt_value")

      assert_equal 1, image_name_column.fetch("pk")
      assert_equal "CURRENT_TIMESTAMP", image_default
      assert_equal "CURRENT_TIMESTAMP", pin_default
      assert_match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/, image_created_at)
      assert_match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/, pin_created_at)
    ensure
      database&.close
    end
  end

  def test_sqlite_store_reports_image_url_insert_progress
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      progress_messages = []

      store.write_image_urls(
        ["https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg"],
        progress: ->(message) { progress_messages << message }
      )

      assert progress_messages.any? { |message| message.match?(/\AImage URL DB transaction started in \d+\.\d{3}s\./) }
      assert progress_messages.any? { |message| message.match?(/\AImage URL DB chunk 1\/1: 1 inserted, 0 duplicated in \d+\.\d{3}s\./) }
      assert progress_messages.any? { |message| message.match?(/\AImage URL DB transaction committed in \d+\.\d{3}s\./) }
    end
  end

  def test_sqlite_store_reports_pin_insert_progress
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      progress_messages = []

      store.write_pins(
        [{ "pin_url" => "https://www.pinterest.com/pin/123456789/", "processed" => false, "interrupted" => false }],
        progress: ->(message) { progress_messages << message }
      )

      assert progress_messages.any? { |message| message.match?(/\APin DB transaction started in \d+\.\d{3}s\./) }
      assert progress_messages.any? { |message| message.match?(/\APin DB chunk 1\/1: 1 inserted, 0 duplicated in \d+\.\d{3}s\./) }
      assert progress_messages.any? { |message| message.match?(/\APin DB transaction committed in \d+\.\d{3}s\./) }
    end
  end

  def test_sqlite_store_disables_wal_autocheckpoint_for_fast_scraper_commits
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      store.setup
      store.send(:with_database) do |database|
        assert_equal "wal", database.get_first_value("PRAGMA journal_mode")
        assert_equal 1, database.get_first_value("PRAGMA synchronous")
        assert_equal 0, database.get_first_value("PRAGMA wal_autocheckpoint")
      end
    end
  end

  def test_sqlite_store_keeps_image_urls_and_pin_urls_unique
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      image_url = "https://i.pinimg.com/originals/ab/cd/ef/photo.jpg"
      replacement_image_url = "https://i.pinimg.com/originals/12/34/56/photo.jpg"
      pin_url = "https://www.pinterest.com/pin/123456789/"

      store.write_image_urls([image_url, replacement_image_url])
      store.write_pins(
        [
          { "pin_url" => pin_url, "processed" => false, "interrupted" => true },
          { "pin_url" => pin_url, "processed" => true, "interrupted" => false }
        ]
      )

      database = SQLite3::Database.new(store.database_file)

      assert_equal 1, database.get_first_value("SELECT COUNT(*) FROM image_urls WHERE image_name = ?", ["photo.jpg"])
      assert_equal image_url, database.get_first_value("SELECT url FROM image_urls WHERE image_name = ?", ["photo.jpg"])
      assert_equal 1, database.get_first_value("SELECT COUNT(*) FROM pins WHERE pin_url = ?", [pin_url])
      assert_equal 0, database.get_first_value("SELECT processed FROM pins WHERE pin_url = ?", [pin_url])
      assert_equal 1, database.get_first_value("SELECT interrupted FROM pins WHERE pin_url = ?", [pin_url])
    ensure
      database&.close
    end
  end

  def test_sqlite_store_updates_interrupted_pins_before_inserting_missing_ones
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      existing_pin_url = "https://www.pinterest.com/pin/123456789/"
      missing_pin_url = "https://www.pinterest.com/pin/987654321/"
      store.write_pins(
        [
          { "pin_url" => existing_pin_url, "processed" => true, "interrupted" => false }
        ]
      )

      store.write_interrupted_pins(
        [
          { "pin_url" => existing_pin_url, "processed" => false, "interrupted" => true },
          { "pin_url" => missing_pin_url, "processed" => false, "interrupted" => true }
        ]
      )

      database = SQLite3::Database.new(store.database_file)

      assert_equal 2, database.get_first_value("SELECT COUNT(*) FROM pins")
      assert_equal 0, database.get_first_value("SELECT processed FROM pins WHERE pin_url = ?", [existing_pin_url])
      assert_equal 1, database.get_first_value("SELECT interrupted FROM pins WHERE pin_url = ?", [existing_pin_url])
      assert_equal 0, database.get_first_value("SELECT processed FROM pins WHERE pin_url = ?", [missing_pin_url])
      assert_equal 1, database.get_first_value("SELECT interrupted FROM pins WHERE pin_url = ?", [missing_pin_url])
    ensure
      database&.close
    end
  end

  def test_sqlite_store_write_pins_returns_inserted_count
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      pin_url = "https://www.pinterest.com/pin/123456789/"

      inserted_count = store.write_pins(
        [
          { "pin_url" => pin_url, "processed" => false, "interrupted" => false },
          { "pin_url" => pin_url, "processed" => false, "interrupted" => false }
        ]
      )

      assert_equal 1, inserted_count
    end
  end

  def test_sqlite_store_updates_processed_pins_before_inserting_missing_ones
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      existing_pin_url = "https://www.pinterest.com/pin/123456789/"
      missing_pin_url = "https://www.pinterest.com/pin/987654321/"
      store.write_pins(
        [
          { "pin_url" => existing_pin_url, "processed" => false, "interrupted" => true }
        ]
      )

      store.write_processed_pins(
        [
          { "pin_url" => existing_pin_url, "processed" => true, "interrupted" => false },
          { "pin_url" => missing_pin_url, "processed" => true, "interrupted" => false }
        ]
      )

      database = SQLite3::Database.new(store.database_file)

      assert_equal 2, database.get_first_value("SELECT COUNT(*) FROM pins")
      assert_equal 1, database.get_first_value("SELECT processed FROM pins WHERE pin_url = ?", [existing_pin_url])
      assert_equal 0, database.get_first_value("SELECT interrupted FROM pins WHERE pin_url = ?", [existing_pin_url])
      assert_equal 1, database.get_first_value("SELECT processed FROM pins WHERE pin_url = ?", [missing_pin_url])
      assert_equal 0, database.get_first_value("SELECT interrupted FROM pins WHERE pin_url = ?", [missing_pin_url])
    ensure
      database&.close
    end
  end

  def test_sqlite_store_migrates_image_urls_to_image_name_primary_key
    Dir.mktmpdir do |dir|
      store = PinterestScrapper::SQLiteStore.new(target_folder: dir)
      FileUtils.mkdir_p(dir)
      database = SQLite3::Database.new(store.database_file)
      database.execute_batch(<<~SQL)
        CREATE TABLE image_urls (
          url TEXT PRIMARY KEY,
          created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO image_urls (url) VALUES ('https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg');
      SQL
      database.close

      store.setup

      database = SQLite3::Database.new(store.database_file)
      database.results_as_hash = true
      image_name_column = database.table_info("image_urls").find { |column| column.fetch("name") == "image_name" }

      assert_equal 1, image_name_column.fetch("pk")
      assert_equal "abcdef.jpg", database.get_first_value("SELECT image_name FROM image_urls")
      assert_equal "https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg", database.get_first_value("SELECT url FROM image_urls")
    ensure
      database&.close
    end
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
      image_downloader = Struct.new(:failed_urls, :downloaded_urls) do
        def download_all(urls, target_folder, progress: nil, stop_requested: nil)
          downloaded_urls.concat(urls)
          saved_files = urls.map { |url| File.join(target_folder, File.basename(URI.parse(url).path)) }
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
      image_downloader = image_downloader.new([], downloaded_urls)

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
      assert_includes progress_messages, "Opening Safari and collecting rendered page URLs: https://www.pinterest.com/pin/123456789/"
      assert_includes progress_messages, "scroll 1: 1 original image URLs, 1 pin URLs, stable 0/3"
      assert_includes progress_messages, "Collected 9 original image URLs and 4 pin URLs."
      assert_includes progress_messages, "4 total pin URLs. 4 inserted. 0 duplicated."
      assert_includes progress_messages, "9 original image URLs ready for database insert."
      assert_includes progress_messages, "9 total image URLs. 9 inserted. 0 duplicated."
      assert_includes progress_messages, "Downloading 9 original images..."
      assert_operator progress_messages.index("Downloading 9 original images..."), :>, progress_messages.index("9 total image URLs. 9 inserted. 0 duplicated.")
      assert_operator progress_messages.index("4 total pin URLs. 4 inserted. 0 duplicated."), :>, progress_messages.index("Saved 9 images. Skipped 0. Failed 0.")
      refute_includes progress_messages, "Downloading image 1/9: 00c5caec39417c90e888c676a7ea8df5.jpg"
      assert_includes progress_messages, "Saved image 9/9: ddeeff.jpg"
      assert_includes progress_messages, "Saved 9 images. Skipped 0. Failed 0."
      assert_includes progress_messages, "Processing next pin: https://www.pinterest.com/pin/555555555/"
      assert_includes progress_messages, "Processing next pin: https://www.pinterest.com/pin/777777777/"
      assert_includes progress_messages, "Processing next pin: https://www.pinterest.com/pin/987654321/"
      assert_equal "https://www.pinterest.com/pin/123456789/", result.pin_url
      assert_equal [
        "https://www.pinterest.com/pin/123456789/",
        "https://www.pinterest.com/pin/555555555/",
        "https://www.pinterest.com/pin/777777777/",
        "https://www.pinterest.com/pin/987654321/"
      ], result.pin_urls
      assert_equal 4, result.pin_url_count
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
      assert_equal 9, result.image_original_url_count
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
      assert File.exist?(result.sqlite_database_file)
      refute File.exist?(File.join(dir, "url_manifest.json"))
      refute File.exist?(File.join(dir, "pins.json"))
      pins = PinterestScrapper::SQLiteStore.new(target_folder: dir).load_pins
      processed_pins = pins.select { |pin| pin.fetch("processed") }
      unprocessed_pins = pins.reject { |pin| pin.fetch("processed") }
      assert_equal [
        "https://www.pinterest.com/pin/123456789/",
        "https://www.pinterest.com/pin/555555555/",
        "https://www.pinterest.com/pin/777777777/",
        "https://www.pinterest.com/pin/987654321/"
      ], processed_pins.map { |pin| pin.fetch("pin_url") }
      assert_empty unprocessed_pins
      database = SQLite3::Database.new(result.sqlite_database_file)
      assert_equal 9, database.get_first_value("SELECT COUNT(*) FROM image_urls")
      assert_equal 4, database.get_first_value("SELECT COUNT(*) FROM pins")
      assert_equal 1, database.get_first_value("SELECT processed FROM pins WHERE pin_url = ?", ["https://www.pinterest.com/pin/123456789/"])
      assert_equal 0, database.get_first_value("SELECT interrupted FROM pins WHERE pin_url = ?", ["https://www.pinterest.com/pin/123456789/"])
      database.close
    end
  end

  def test_app_pauses_when_machine_is_locked
    Dir.mktmpdir do |dir|
      page_fetcher = Struct.new(:body) do
        def fetch(url)
          PinterestScrapper::PageFetcher::Page.new(url: url.to_s, body: body)
        end
      end.new("<html></html>")
      safari_snapshot = Struct.new(:captures) do
        def capture(url, progress: nil)
          captures << url.to_s
          PinterestScrapper::SafariSnapshot::Snapshot.new(
            url: url.to_s,
            body: "<link rel=\"canonical\" href=\"#{url}\">",
            urls: []
          )
        end
      end.new([])
      image_downloader = Struct.new(:download_calls) do
        def download_all(_urls, _target_folder, progress: nil, stop_requested: nil)
          download_calls << true
          PinterestScrapper::ImageDownloader::Result.new(
            saved_files: [],
            skipped_files: [],
            failed_urls: []
          )
        end
      end.new([])
      session_lock = Struct.new(:states) do
        def locked?
          states.empty? ? false : states.shift
        end
      end.new([true, false, true, false])
      progress_messages = []

      PinterestScrapper::App.new(
        target_folder: dir,
        pinterest_url: URI.parse("https://www.pinterest.com/pin/123456789/"),
        page_fetcher: page_fetcher,
        safari_snapshot: safari_snapshot,
        image_downloader: image_downloader,
        session_lock: session_lock,
        lock_check_interval: 0,
        progress: ->(message) { progress_messages << message }
      ).run

      assert_equal ["https://www.pinterest.com/pin/123456789/"], safari_snapshot.captures
      assert_equal [true], image_downloader.download_calls
      assert_equal 2, progress_messages.count("Machine is locked. Pausing until it is unlocked...")
      assert_equal 2, progress_messages.count("Machine unlocked. Resuming...")
    end
  end

  def test_app_leaves_current_pin_unprocessed_when_stop_is_requested_during_downloads
    Dir.mktmpdir do |dir|
      page_fetcher = Struct.new(:body) do
        def fetch(url)
          PinterestScrapper::PageFetcher::Page.new(url: url.to_s, body: body)
        end
      end.new("<html></html>")
      safari_snapshot = Struct.new(:body) do
        def capture(url, progress: nil)
          PinterestScrapper::SafariSnapshot::Snapshot.new(url: url.to_s, body: body, urls: [])
        end
      end.new(<<~HTML)
        <link rel="canonical" href="https://www.pinterest.com/pin/123456789/">
        <img src="https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg">
      HTML
      stop_state = { requested: false }
      image_downloader = Struct.new(:stop_state) do
        def download_all(urls, target_folder, progress: nil, stop_requested: nil)
          stop_state[:requested] = true
          PinterestScrapper::ImageDownloader::Result.new(
            saved_files: [],
            skipped_files: [],
            failed_urls: []
          )
        end
      end.new(stop_state)
      progress_messages = []

      result = PinterestScrapper::App.new(
        target_folder: dir,
        pinterest_url: URI.parse("https://www.pinterest.com/pin/123456789/"),
        page_fetcher: page_fetcher,
        safari_snapshot: safari_snapshot,
        image_downloader: image_downloader,
        progress: ->(message) { progress_messages << message },
        stop_requested: -> { stop_state[:requested] }
      ).run

      pins = PinterestScrapper::SQLiteStore.new(target_folder: dir).load_pins

      assert_includes progress_messages, "Stop requested. Marking current pin as interrupted."
      assert_equal [
        { "pin_url" => "https://www.pinterest.com/pin/123456789/", "processed" => false, "interrupted" => true }
      ], pins
    end
  end

  def test_app_skips_collected_pin_insert_when_stop_is_requested_during_downloads
    Dir.mktmpdir do |dir|
      page_fetcher = Struct.new(:body) do
        def fetch(url)
          PinterestScrapper::PageFetcher::Page.new(url: url.to_s, body: body)
        end
      end.new("<html></html>")
      safari_snapshot = Struct.new(:body) do
        def capture(url, progress: nil)
          PinterestScrapper::SafariSnapshot::Snapshot.new(url: url.to_s, body: body, urls: [])
        end
      end.new(<<~HTML)
        <link rel="canonical" href="https://www.pinterest.com/pin/123456789/">
        <a href="https://www.pinterest.com/pin/987654321/">Related</a>
        <img src="https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg">
      HTML
      stop_state = { requested: false }
      image_downloader = Struct.new(:stop_state) do
        def download_all(_urls, _target_folder, progress: nil, stop_requested: nil)
          stop_state[:requested] = true
          PinterestScrapper::ImageDownloader::Result.new(saved_files: [], skipped_files: [], failed_urls: [])
        end
      end.new(stop_state)
      store = FakeSQLiteStore.new(
        image_urls: [],
        pins: [],
        written_image_url_batches: [],
        written_pin_batches: []
      )

      PinterestScrapper::App.new(
        target_folder: dir,
        pinterest_url: URI.parse("https://www.pinterest.com/pin/123456789/"),
        page_fetcher: page_fetcher,
        safari_snapshot: safari_snapshot,
        image_downloader: image_downloader,
        sqlite_store: store,
        stop_requested: -> { stop_state[:requested] }
      ).run

      assert_equal [
        [{ "pin_url" => "https://www.pinterest.com/pin/123456789/", "processed" => false, "interrupted" => true }]
      ], store.written_pin_batches
      assert_equal [
        { "pin_url" => "https://www.pinterest.com/pin/123456789/", "processed" => false, "interrupted" => true }
      ], store.pins
    end
  end

  def test_app_uses_counts_without_loading_full_tables_after_stop
    Dir.mktmpdir do |dir|
      page_fetcher = Struct.new(:body) do
        def fetch(url)
          PinterestScrapper::PageFetcher::Page.new(url: url.to_s, body: body)
        end
      end.new("<html></html>")
      safari_snapshot = Struct.new(:body) do
        def capture(url, progress: nil)
          PinterestScrapper::SafariSnapshot::Snapshot.new(url: url.to_s, body: body, urls: [])
        end
      end.new(<<~HTML)
        <link rel="canonical" href="https://www.pinterest.com/pin/123456789/">
        <img src="https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg">
      HTML
      stop_state = { requested: false }
      image_downloader = Struct.new(:stop_state) do
        def download_all(_urls, _target_folder, progress: nil, stop_requested: nil)
          stop_state[:requested] = true
          PinterestScrapper::ImageDownloader::Result.new(saved_files: [], skipped_files: [], failed_urls: [])
        end
      end.new(stop_state)
      store = FakeSQLiteStore.new(
        image_urls: [],
        pins: [],
        written_image_url_batches: [],
        written_pin_batches: []
      )
      def store.load_image_urls
        raise "loaded image URLs"
      end
      def store.load_pins
        raise "loaded pins"
      end
      def store.image_url_count
        raise "counted image URLs"
      end
      def store.pin_count
        raise "counted pins"
      end

      result = PinterestScrapper::App.new(
        target_folder: dir,
        pinterest_url: URI.parse("https://www.pinterest.com/pin/123456789/"),
        page_fetcher: page_fetcher,
        safari_snapshot: safari_snapshot,
        image_downloader: image_downloader,
        sqlite_store: store,
        stop_requested: -> { stop_state[:requested] }
      ).run

      assert_nil result.image_original_url_count
      assert_nil result.pin_url_count
      assert result.stopped_early
      assert_empty result.image_original_urls
      assert_empty result.pin_urls
    end
  end

  def test_app_closes_random_pin_cursor_before_marking_pin_interrupted
    Dir.mktmpdir do |dir|
      page_fetcher = Struct.new(:body) do
        def fetch(url)
          PinterestScrapper::PageFetcher::Page.new(url: url.to_s, body: body)
        end
      end.new("<html></html>")
      safari_snapshot = Struct.new(:bodies) do
        def capture(url, progress: nil)
          PinterestScrapper::SafariSnapshot::Snapshot.new(url: url.to_s, body: bodies.fetch(url.to_s), urls: [])
        end
      end.new({
        "https://www.pinterest.com/pin/111111111/" => <<~HTML,
          <link rel="canonical" href="https://www.pinterest.com/pin/111111111/">
          <a href="https://www.pinterest.com/pin/222222222/">Next</a>
          <img src="https://i.pinimg.com/originals/11/11/11/111111.jpg">
        HTML
        "https://www.pinterest.com/pin/222222222/" => <<~HTML
          <link rel="canonical" href="https://www.pinterest.com/pin/222222222/">
          <img src="https://i.pinimg.com/originals/22/22/22/222222.jpg">
        HTML
      })
      stop_state = { calls: 0 }
      image_downloader = Struct.new(:stop_state) do
        def download_all(_urls, _target_folder, progress: nil, stop_requested: nil)
          stop_state[:calls] += 1
          stop_state[:requested] = true if stop_state[:calls] == 2
          PinterestScrapper::ImageDownloader::Result.new(saved_files: [], skipped_files: [], failed_urls: [])
        end
      end.new(stop_state)
      store = FakeSQLiteStore.new(
        image_urls: [],
        pins: [],
        written_image_url_batches: [],
        written_pin_batches: []
      )

      PinterestScrapper::App.new(
        target_folder: dir,
        pinterest_url: URI.parse("https://www.pinterest.com/pin/111111111/"),
        page_fetcher: page_fetcher,
        safari_snapshot: safari_snapshot,
        image_downloader: image_downloader,
        sqlite_store: store,
        stop_requested: -> { stop_state[:requested] }
      ).run

      assert_equal [
        { "pin_url" => "https://www.pinterest.com/pin/222222222/", "processed" => false, "interrupted" => true }
      ], store.pins.select { |pin| pin.fetch("pin_url") == "https://www.pinterest.com/pin/222222222/" }
    end
  end

  def test_app_downloads_only_image_urls_inserted_into_database
    Dir.mktmpdir do |dir|
      page_fetcher = Struct.new(:body) do
        def fetch(url)
          PinterestScrapper::PageFetcher::Page.new(url: url.to_s, body: body)
        end
      end.new("<html></html>")
      safari_snapshot = Struct.new(:body) do
        def capture(url, progress: nil)
          PinterestScrapper::SafariSnapshot::Snapshot.new(url: url.to_s, body: body, urls: [])
        end
      end.new(<<~HTML)
        <link rel="canonical" href="https://www.pinterest.com/pin/123456789/">
        <img src="https://i.pinimg.com/originals/ab/cd/ef/existing.jpg">
        <img src="https://i.pinimg.com/originals/ab/cd/ef/new.jpg">
      HTML
      image_downloader = Struct.new(:downloaded_urls) do
        def download_all(urls, _target_folder, progress: nil, stop_requested: nil)
          downloaded_urls.concat(urls)
          PinterestScrapper::ImageDownloader::Result.new(saved_files: [], skipped_files: [], failed_urls: [])
        end
      end.new([])
      store = FakeSQLiteStore.new(
        image_urls: ["https://i.pinimg.com/originals/ab/cd/ef/existing.jpg"],
        pins: [],
        written_image_url_batches: [],
        written_pin_batches: []
      )

      PinterestScrapper::App.new(
        target_folder: dir,
        pinterest_url: URI.parse("https://www.pinterest.com/pin/123456789/"),
        page_fetcher: page_fetcher,
        safari_snapshot: safari_snapshot,
        image_downloader: image_downloader,
        sqlite_store: store
      ).run

      expected_urls = [
        "https://i.pinimg.com/originals/ab/cd/ef/existing.jpg",
        "https://i.pinimg.com/originals/ab/cd/ef/new.jpg"
      ]
      assert_equal [expected_urls], store.written_image_url_batches
      assert_equal ["https://i.pinimg.com/originals/ab/cd/ef/new.jpg"], image_downloader.downloaded_urls
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
      downloader = PinterestScrapper::ImageDownloader.new(fetcher: fetcher, workers: 1)
      urls = [
        "https://i.pinimg.com/originals/small/photo.png",
        "https://i.pinimg.com/originals/large/photo.png"
      ]

      result = downloader.download_all(urls, dir)
      destination = File.join(dir, "ph", "ot", "photo.png")

      assert_equal [destination], result.saved_files
      assert_empty result.failed_urls
      assert_includes File.binread(destination), "large"
      refute File.exist?(File.join(dir, "ph", "ot", "photo_2.png"))
    end
  end

  def test_image_downloader_uses_two_level_folder_structure_from_filename
    Dir.mktmpdir do |dir|
      fetcher = ->(_url) { png_bytes(width: 10, height: 10, marker: "image") }
      downloader = PinterestScrapper::ImageDownloader.new(fetcher: fetcher, workers: 1)
      url = "https://i.pinimg.com/originals/00/c5/ca/00c5caec39417c90e888c676a7ea8df5.jpg"

      result = downloader.download_all([url], dir)
      destination = File.join(dir, "00", "c5", "00c5caec39417c90e888c676a7ea8df5.jpg")

      assert_equal [destination], result.saved_files
      assert File.exist?(destination)
    end
  end

  def test_image_downloader_downloads_in_parallel
    Dir.mktmpdir do |dir|
      mutex = Mutex.new
      active_downloads = 0
      max_active_downloads = 0
      fetcher = lambda do |_url|
        mutex.synchronize do
          active_downloads += 1
          max_active_downloads = [max_active_downloads, active_downloads].max
        end
        sleep 0.05
        mutex.synchronize { active_downloads -= 1 }
        png_bytes(width: 10, height: 10, marker: "image")
      end
      downloader = PinterestScrapper::ImageDownloader.new(fetcher: fetcher, workers: 3)
      urls = [
        "https://i.pinimg.com/originals/aa/aa/aa/aafile.png",
        "https://i.pinimg.com/originals/bb/bb/bb/bbfile.png",
        "https://i.pinimg.com/originals/cc/cc/cc/ccfile.png"
      ]

      result = downloader.download_all(urls, dir)

      assert_operator max_active_downloads, :>, 1
      assert_equal 3, result.saved_files.length
    end
  end

  def test_image_downloader_uses_ten_workers_by_default
    assert_equal 10, PinterestScrapper::ImageDownloader::DEFAULT_WORKERS
  end

  def test_safari_snapshot_parses_and_remembers_unique_tab_marker_output
    snapshot = PinterestScrapper::SafariSnapshot.new
    payload = {
      url: "https://www.pinterest.com/pin/123/",
      html: "<html></html>",
      urls: []
    }

    parsed = snapshot.send(:parse_script_output, "pinterest-scrapper-test-marker\t#{JSON.generate(payload)}")
    next_script = snapshot.send(:apple_script, "https://www.pinterest.com/pin/456/")

    assert_equal payload.fetch(:url), parsed.fetch("url")
    assert_includes next_script, "set tabMarker to \"pinterest-scrapper-test-marker\""
    refute_includes next_script, "preferredTabIndex"
    refute_includes next_script, "targetTabIndex"
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
      downloader = PinterestScrapper::ImageDownloader.new(fetcher: fetcher, workers: 1)
      urls = [
        "https://i.pinimg.com/originals/large/photo.png",
        "https://i.pinimg.com/originals/small/photo.png"
      ]

      result = downloader.download_all(urls, dir)
      destination = File.join(dir, "ph", "ot", "photo.png")

      assert_equal [destination], result.saved_files
      assert_equal [destination], result.skipped_files
      assert_empty result.failed_urls
      assert_includes File.binread(destination), "large"
      refute File.exist?(File.join(dir, "ph", "ot", "photo_2.png"))
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
      downloader = PinterestScrapper::ImageDownloader.new(fetcher: fetcher, workers: 1)
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

  def test_image_downloader_ends_gracefully_when_stop_is_requested
    Dir.mktmpdir do |dir|
      fetcher = ->(_url) { png_bytes(width: 10, height: 10, marker: "image") }
      downloader = PinterestScrapper::ImageDownloader.new(fetcher: fetcher, workers: 1)
      progress_messages = []
      stop_checks = 0
      stop_requested = lambda do
        stop_checks += 1
        stop_checks > 1
      end
      urls = [
        "https://i.pinimg.com/originals/a/photo-a.png",
        "https://i.pinimg.com/originals/b/photo-b.png"
      ]

      result = downloader.download_all(
        urls,
        dir,
        progress: ->(message) { progress_messages << message },
        stop_requested: stop_requested
      )

      assert_equal [File.join(dir, "ph", "ot", "photo-a.png")], result.saved_files
      assert_empty result.skipped_files
      assert_empty result.failed_urls
      assert_includes progress_messages, "Stop requested. Ending downloads gracefully."
      refute File.exist?(File.join(dir, "ph", "ot", "photo-b.png"))
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
          pin_url_count: 1,
          urls: [pinterest_url],
          image_original_urls: ["https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg"],
          image_original_url_count: 1,
          saved_image_files: [File.join(target_folder, "abcdef.jpg")],
          skipped_image_files: [],
          failed_image_urls: [],
          sqlite_database_file: File.join(target_folder, "pinterest_scrapper.sqlite3"),
          stopped_early: false
        )
      )
    end
  end
end
