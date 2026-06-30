# frozen_string_literal: true

require "fileutils"
require "digest"
require "set"
require "sqlite3"
require "uri"

module PinterestScrapper
  class SQLiteStore
    DEFAULT_FILENAME = "pinterest_scrapper.sqlite3"
    IMAGE_URL_INSERT_CHUNK_SIZE = 400
    PIN_INSERT_CHUNK_SIZE = 300
    WAL_AUTOCHECKPOINT_PAGES = 0
    BUSY_TIMEOUT_MILLISECONDS = 5_000
    CHECKPOINT_BUSY_TIMEOUT_MILLISECONDS = 100
    CACHE_SIZE_KIB = 200_000
    MMAP_SIZE_BYTES = 256 * 1024 * 1024
    TRANSACTION_BEGIN_SQL = "BEGIN"

    class PinCursor
      def initialize(database_file)
        @database = SQLite3::Database.new(database_file)
        @database.results_as_hash = true
        @database.busy_timeout(BUSY_TIMEOUT_MILLISECONDS)
        @database.execute("PRAGMA synchronous = NORMAL")
        @database.execute("PRAGMA wal_autocheckpoint = #{WAL_AUTOCHECKPOINT_PAGES}")
        @database.execute("PRAGMA cache_size = -#{CACHE_SIZE_KIB}")
        @database.execute("PRAGMA mmap_size = #{MMAP_SIZE_BYTES}")
        @result_sets = random_rowid_result_sets
      end

      def next_pin_url
        loop do
          result_set = result_sets.first
          return nil unless result_set

          row = result_set.next
          return row.fetch("pin_url") if row

          close_result_set(result_sets.shift)
        end
      end

      def close
        result_sets.each { |result_set| close_result_set(result_set) }
        result_sets.clear
        database&.close
      end

      private

      attr_reader :database, :result_sets

      def random_rowid_result_sets
        max_rowid = database.get_first_value("SELECT COALESCE(MAX(rowid), 0) FROM pins").to_i
        return [] if max_rowid.zero?

        start_rowid = database.get_first_value("SELECT ABS(RANDOM()) % ? + 1", [max_rowid]).to_i
        [
          pins_from_rowid("rowid >= ?", start_rowid),
          pins_from_rowid("rowid < ?", start_rowid)
        ]
      end

      def pins_from_rowid(rowid_predicate, rowid)
        database.query(
          <<~SQL,
            SELECT pin_url
            FROM pins NOT INDEXED
            WHERE processed = 0
              AND interrupted = 0
              AND #{rowid_predicate}
            ORDER BY rowid
          SQL
          [rowid]
        )
      end

      def close_result_set(result_set)
        result_set&.close unless result_set&.closed?
      end
    end

    class EmptyPinCursor
      def next_pin_url
        nil
      end

      def close; end
    end

    class ImageUrlTransaction
      def initialize(store, database)
        @store = store
        @database = database
      end

      def insert(url)
        store.send(:insert_single_image_url, database, url)
      rescue SQLite3::Exception
        false
      end

      private

      attr_reader :store, :database
    end

    attr_reader :database_file

    def initialize(target_folder:, database_file: nil)
      @database_file = File.expand_path(database_file || File.join(target_folder, DEFAULT_FILENAME))
      @setup_complete = false
      @database = nil
      @wal_checkpoint_mutex = Mutex.new
      @wal_checkpoint_thread = nil
    end

    def close
      @database&.close
      @database = nil
    end

    def setup
      return if @setup_complete

      FileUtils.mkdir_p(File.dirname(database_file))

      with_database do |database|
        database.execute("PRAGMA journal_mode = WAL")
        configure_database_connection(database)
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

      @setup_complete = true
    end

    def load_image_urls
      return [] unless File.exist?(database_file)

      setup
      with_database do |database|
        database.execute("SELECT url FROM image_urls ORDER BY url").map { |row| row.fetch("url") }
      end
    end

    def image_url_count
      return 0 unless File.exist?(database_file)

      setup
      with_database do |database|
        database.get_first_value("SELECT COUNT(*) FROM image_urls").to_i
      end
    end

    def load_pins
      return [] unless File.exist?(database_file)

      setup
      with_database do |database|
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
    end

    def pin_count
      return 0 unless File.exist?(database_file)

      setup
      with_database do |database|
        database.get_first_value("SELECT COUNT(*) FROM pins").to_i
      end
    end

    def next_interrupted_pin_url
      return nil unless File.exist?(database_file)

      setup
      with_database do |database|
        database.get_first_value(<<~SQL)
          SELECT pin_url
          FROM pins
          WHERE processed = 0
            AND interrupted = 1
          ORDER BY updated_at, created_at, pin_url
          LIMIT 1
        SQL
      end
    end

    def random_unprocessed_pin_cursor
      return EmptyPinCursor.new unless File.exist?(database_file)

      setup
      PinCursor.new(database_file)
    end

    def next_unprocessed_pin_url
      interrupted_pin_url = next_interrupted_pin_url
      return interrupted_pin_url if interrupted_pin_url

      cursor = random_unprocessed_pin_cursor
      cursor.next_pin_url
    ensure
      cursor&.close
    end

    def write_image_urls(urls, progress: nil)
      urls = Array(urls)
      return [] if urls.empty?

      setup

      with_database do |database|
        inserted_urls = []
        chunks = urls.each_slice(IMAGE_URL_INSERT_CHUNK_SIZE).to_a

        transaction_start_time = monotonic_time
        database.execute(TRANSACTION_BEGIN_SQL)
        progress&.call("Image URL DB transaction started in #{elapsed_time(transaction_start_time)}.")

        begin
          chunks.each_with_index do |url_chunk, index|
            chunk_start_time = monotonic_time
            inserted_chunk_urls = insert_image_url_chunk(database, url_chunk)
            inserted_urls.concat(inserted_chunk_urls)
            duplicated_count = url_chunk.length - inserted_chunk_urls.length
            progress&.call(
              "Image URL DB chunk #{index + 1}/#{chunks.length}: " \
              "#{inserted_chunk_urls.length} inserted, #{duplicated_count} duplicated in #{elapsed_time(chunk_start_time)}."
            )
          end

          commit_start_time = monotonic_time
          database.execute("COMMIT")
          progress&.call("Image URL DB transaction committed in #{elapsed_time(commit_start_time)}.")
        rescue StandardError
          database.execute("ROLLBACK") rescue nil
          raise
        end

        inserted_urls
      end
    end

    def with_image_url_transaction(progress: nil)
      setup

      with_database do |database|
        transaction_start_time = monotonic_time
        database.execute(TRANSACTION_BEGIN_SQL)
        progress&.call("Image URL DB transaction started in #{elapsed_time(transaction_start_time)}.")

        begin
          result = yield ImageUrlTransaction.new(self, database)

          commit_start_time = monotonic_time
          database.execute("COMMIT")
          progress&.call("Image URL DB transaction committed in #{elapsed_time(commit_start_time)}.")
          result
        rescue StandardError
          database.execute("ROLLBACK") rescue nil
          raise
        end
      end
    end

    def write_pins(pins, progress: nil)
      pins = Array(pins)
      return 0 if pins.empty?

      setup

      with_database do |database|
        inserted_count = 0
        chunk_count = (pins.length.to_f / PIN_INSERT_CHUNK_SIZE).ceil

        transaction_start_time = monotonic_time
        database.execute(TRANSACTION_BEGIN_SQL)
        progress&.call("Pin DB transaction started in #{elapsed_time(transaction_start_time)}.")

        begin
          pins.each_slice(PIN_INSERT_CHUNK_SIZE).with_index do |pin_chunk, index|
            chunk_start_time = monotonic_time
            inserted_chunk_count = insert_pin_chunk(database, pin_chunk)
            inserted_count += inserted_chunk_count
            duplicated_count = pin_chunk.length - inserted_chunk_count
            progress&.call(
              "Pin DB chunk #{index + 1}/#{chunk_count}: " \
              "#{inserted_chunk_count} inserted, #{duplicated_count} duplicated in #{elapsed_time(chunk_start_time)}."
            )
          end

          commit_start_time = monotonic_time
          database.execute("COMMIT")
          progress&.call("Pin DB transaction committed in #{elapsed_time(commit_start_time)}.")
        rescue StandardError
          database.execute("ROLLBACK") rescue nil
          raise
        end

        inserted_count
      end
    end

    def write_interrupted_pins(pins)
      write_pins_update_first(pins)
    end

    def write_processed_pins(pins)
      write_pins_update_first(pins)
    end

    def wal_checkpoint
      setup

      with_database do |database|
        database.execute("PRAGMA wal_checkpoint(PASSIVE)")
      end
    end

    def wal_checkpoint_async(progress: nil)
      setup

      wal_checkpoint_mutex.synchronize do
        return :running if wal_checkpoint_thread&.alive?

        @wal_checkpoint_thread = Thread.new do
          wal_checkpoint_start_time = monotonic_time
          checkpoint_database = nil

          begin
            checkpoint_database = SQLite3::Database.new(database_file)
            checkpoint_database.results_as_hash = true
            configure_database_connection(checkpoint_database)
            checkpoint_database.busy_timeout(CHECKPOINT_BUSY_TIMEOUT_MILLISECONDS)
            checkpoint_database.execute("PRAGMA wal_checkpoint(PASSIVE)")
            progress&.call("WAL checkpoint completed in #{elapsed_time(wal_checkpoint_start_time)}.")
          rescue SQLite3::Exception => e
            progress&.call("WAL checkpoint skipped: #{e.class}: #{e.message}")
          ensure
            checkpoint_database&.close
          end
        end

        :started
      end
    end

    private

    attr_reader :wal_checkpoint_mutex, :wal_checkpoint_thread

    def insert_image_url_chunk(database, urls)
      existing_image_names, existing_urls = existing_image_url_keys(database, urls)
      urls_to_insert = urls.reject do |url|
        existing_image_names.include?(image_name_for(url)) || existing_urls.include?(url)
      end
      return [] if urls_to_insert.empty?

      values_sql = Array.new(urls_to_insert.length, "(?, ?)").join(", ")
      statement = database.prepare(<<~SQL)
        INSERT OR IGNORE INTO image_urls (image_name, url)
        VALUES #{values_sql}
        RETURNING url
      SQL
      bind_values = urls_to_insert.flat_map { |url| [image_name_for(url), url] }
      result_set = statement.execute(*bind_values)
      result_set.map { |row| row.fetch("url") }
    ensure
      result_set&.close
      close_statement(statement)
    end

    def insert_single_image_url(database, url)
      statement = database.prepare(<<~SQL)
        INSERT INTO image_urls (image_name, url)
        VALUES (?, ?)
      SQL
      statement.execute(image_name_for(url), url)
      true
    ensure
      close_statement(statement)
    end

    def insert_pin_chunk(database, pins)
      existing_urls = existing_pin_urls(database, pins)
      pins_to_insert = pins.reject { |pin| existing_urls.include?(pin.fetch("pin_url")) }
      return 0 if pins_to_insert.empty?

      values_sql = Array.new(pins_to_insert.length, "(?, ?, ?, CURRENT_TIMESTAMP)").join(", ")
      statement = database.prepare(<<~SQL)
        INSERT OR IGNORE INTO pins (pin_url, processed, interrupted, updated_at)
        VALUES #{values_sql}
        RETURNING pin_url
      SQL
      bind_values = pins_to_insert.flat_map do |pin|
        [
          pin.fetch("pin_url"),
          pin["processed"] ? 1 : 0,
          pin["interrupted"] ? 1 : 0
        ]
      end
      result_set = statement.execute(*bind_values)
      result_set.map { |row| row.fetch("pin_url") }.length
    ensure
      result_set&.close
      close_statement(statement)
    end

    def existing_image_url_keys(database, urls)
      image_names = urls.map { |url| image_name_for(url) }
      placeholders = Array.new(urls.length, "?").join(", ")
      statement = database.prepare(<<~SQL)
        SELECT image_name, url
        FROM image_urls
        WHERE image_name IN (#{placeholders})
           OR url IN (#{placeholders})
      SQL
      result_set = statement.execute(*(image_names + urls))
      existing_image_names = Set.new
      existing_urls = Set.new
      result_set.each do |row|
        existing_image_names << row.fetch("image_name")
        existing_urls << row.fetch("url")
      end
      [existing_image_names, existing_urls]
    ensure
      result_set&.close
      close_statement(statement)
    end

    def existing_pin_urls(database, pins)
      pin_urls = pins.map { |pin| pin.fetch("pin_url") }
      placeholders = Array.new(pin_urls.length, "?").join(", ")
      statement = database.prepare(<<~SQL)
        SELECT pin_url
        FROM pins
        WHERE pin_url IN (#{placeholders})
      SQL
      result_set = statement.execute(*pin_urls)
      result_set.each_with_object(Set.new) { |row, set| set << row.fetch("pin_url") }
    ensure
      result_set&.close
      close_statement(statement)
    end

    def close_statement(statement)
      statement&.close unless statement&.closed?
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_time(start_time)
      "#{format('%.3f', monotonic_time - start_time)}s"
    end

    def write_pins_update_first(pins)
      pins = Array(pins)
      return if pins.empty?

      setup

      with_database do |database|
        database.transaction do
          update_statement = database.prepare(<<~SQL)
            UPDATE pins
            SET processed = ?,
                interrupted = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE pin_url = ?
          SQL
          insert_statement = database.prepare(<<~SQL)
            INSERT OR IGNORE INTO pins (pin_url, processed, interrupted, updated_at)
            VALUES (?, ?, ?, CURRENT_TIMESTAMP)
          SQL
          begin
            pins.each do |pin|
              processed = pin["processed"] ? 1 : 0
              interrupted = pin["interrupted"] ? 1 : 0
              pin_url = pin.fetch("pin_url")

              update_statement.execute(processed, interrupted, pin_url)
              next unless database.changes.zero?

              insert_statement.execute(pin_url, processed, interrupted)
            end
          ensure
            close_statement(update_statement)
            close_statement(insert_statement)
          end
        end
      end
    end

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
        insert_statement = database.prepare(<<~SQL)
          INSERT OR IGNORE INTO image_urls (image_name, url, created_at)
          VALUES (?, ?, COALESCE(?, CURRENT_TIMESTAMP))
        SQL
        begin
          database.execute("SELECT url, created_at FROM image_urls_legacy").each do |row|
            insert_statement.execute(image_name_for(row.fetch("url")), row.fetch("url"), row["created_at"])
          end
        ensure
          close_statement(insert_statement)
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
      yield database_connection
    end

    def database_connection
      @database ||= begin
        database = SQLite3::Database.new(database_file)
        database.results_as_hash = true
        configure_database_connection(database)
        database
      end
    end

    def configure_database_connection(database)
      database.busy_timeout(BUSY_TIMEOUT_MILLISECONDS)
      database.execute("PRAGMA synchronous = NORMAL")
      database.execute("PRAGMA wal_autocheckpoint = #{WAL_AUTOCHECKPOINT_PAGES}")
      database.execute("PRAGMA temp_store = MEMORY")
      database.execute("PRAGMA cache_size = -#{CACHE_SIZE_KIB}")
      database.execute("PRAGMA mmap_size = #{MMAP_SIZE_BYTES}")
    end
  end
end
