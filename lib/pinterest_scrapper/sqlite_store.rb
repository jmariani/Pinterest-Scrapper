# frozen_string_literal: true

require "fileutils"
require "digest"
require "sqlite3"
require "uri"

module PinterestScrapper
  class SQLiteStore
    DEFAULT_FILENAME = "pinterest_scrapper.sqlite3"

    attr_reader :database_file

    def initialize(target_folder:, database_file: nil)
      @database_file = File.expand_path(database_file || File.join(target_folder, DEFAULT_FILENAME))
    end

    def setup
      FileUtils.mkdir_p(File.dirname(database_file))

      with_database do |database|
        database.execute("PRAGMA journal_mode = WAL")
        setup_image_urls_table(database)
        database.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS pins (
            pin_url TEXT PRIMARY KEY,
            processed INTEGER NOT NULL DEFAULT 0,
            interrupted INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
          );

          CREATE UNIQUE INDEX IF NOT EXISTS index_image_urls_url
            ON image_urls (url);

          CREATE INDEX IF NOT EXISTS index_image_urls_created_at
            ON image_urls (created_at);

          CREATE INDEX IF NOT EXISTS index_pins_processing_state
            ON pins (processed, interrupted, created_at, pin_url);

          CREATE INDEX IF NOT EXISTS index_pins_updated_at
            ON pins (updated_at);
        SQL
      end
    end

    def load_url_manifest
      return { "urls" => [], "image_original_urls" => [] } unless File.exist?(database_file)

      setup
      urls = with_database do |database|
        database.execute("SELECT url FROM image_urls ORDER BY url").map { |row| row.fetch("url") }
      end
      { "urls" => urls, "image_original_urls" => urls }
    end

    def load_pins_manifest
      return { "pins" => [] } unless File.exist?(database_file)

      setup
      pins = with_database do |database|
        database.execute(<<~SQL).map do |row|
          SELECT pin_url, processed, interrupted
          FROM pins
          ORDER BY created_at, pin_url
        SQL
          {
            "pin_url" => row.fetch("pin_url"),
            "processed" => row.fetch("processed").to_i == 1,
            "interrupted" => row.fetch("interrupted").to_i == 1
          }
        end
      end
      { "pins" => pins }
    end

    def write_state(url_manifest:, pins_manifest:)
      setup

      with_database do |database|
        database.transaction do
          Array(url_manifest["image_original_urls"] || url_manifest["urls"]).each do |url|
            database.execute(
              <<~SQL,
                INSERT INTO image_urls (image_name, url)
                VALUES (?, ?)
                ON CONFLICT(image_name) DO UPDATE SET
                  url = excluded.url
              SQL
              [image_name_for(url), url]
            )
          end

          Array(pins_manifest["pins"]).each do |pin|
            database.execute(
              <<~SQL,
                INSERT INTO pins (pin_url, processed, interrupted, updated_at)
                VALUES (?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(pin_url) DO UPDATE SET
                  processed = excluded.processed,
                  interrupted = excluded.interrupted,
                  updated_at = CURRENT_TIMESTAMP
              SQL
              [
                pin.fetch("pin_url"),
                pin["processed"] ? 1 : 0,
                pin["interrupted"] ? 1 : 0
              ]
            )
          end
        end
      end
    end

    private

    def setup_image_urls_table(database)
      unless table_exists?(database, "image_urls")
        create_image_urls_table(database)
        return
      end

      columns = database.table_info("image_urls").map { |column| column.fetch("name") }
      return if columns.include?("image_name")

      database.transaction do
        database.execute("ALTER TABLE image_urls RENAME TO image_urls_legacy")
        create_image_urls_table(database)
        database.execute("SELECT url, created_at FROM image_urls_legacy").each do |row|
          database.execute(
            <<~SQL,
              INSERT OR IGNORE INTO image_urls (image_name, url, created_at)
              VALUES (?, ?, COALESCE(?, CURRENT_TIMESTAMP))
            SQL
            [image_name_for(row.fetch("url")), row.fetch("url"), row["created_at"]]
          )
        end
        database.execute("DROP TABLE image_urls_legacy")
      end
    end

    def create_image_urls_table(database)
      database.execute(<<~SQL)
        CREATE TABLE image_urls (
          image_name TEXT PRIMARY KEY,
          url TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
      SQL
    end

    def table_exists?(database, table_name)
      database.get_first_value(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table_name]
      )
    end

    def image_name_for(url)
      basename = File.basename(URI.parse(url.to_s).path)
      return basename unless basename.nil? || basename.empty? || basename == "/"

      "image-#{Digest::SHA256.hexdigest(url.to_s)}"
    rescue URI::InvalidURIError
      "image-#{Digest::SHA256.hexdigest(url.to_s)}"
    end

    def with_database
      database = SQLite3::Database.new(database_file)
      database.results_as_hash = true
      yield database
    ensure
      database&.close
    end
  end
end
