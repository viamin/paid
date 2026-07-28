# frozen_string_literal: true

require "open3"

module Database
  # SafetyBackup snapshots dev/test databases before destructive operations so
  # a mistyped `bin/rails db:reset` (or db:schema:load / db:purge /
  # db:truncate_all / db:drop) -- or a stray DatabaseTasks.load_schema / purge /
  # truncate_tables call from a console/runner -- can never silently destroy
  # data.
  #
  # Two complementary entry points, wired from
  # config/initializers/database_safety_backup.rb:
  #
  #   * backup_before_destructive! -- runs from after_initialize when the
  #     top-level command is a DROP-path Rake task (db:drop / db:reset /
  #     db:migrate:reset, plus their :all and per-DB variants). The prepend hook
  #     below cannot save these: by the time load_schema/purge run inside
  #     db:reset, the DROP DATABASE has already destroyed the data.
  #   * snapshot_if_populated!(db_config) -- prepended onto
  #     ActiveRecord::Tasks::DatabaseTasks#load_schema / #purge /
  #     #truncate_tables, so it also guards db:schema:load, db:purge,
  #     db:truncate_all, db:seed:replant, the db:test:* rebuild path,
  #     db:prepare's internal reload, and direct console/runner misuse.
  #
  # Skipped in production and CI, on databases provably empty, and when
  # SKIP_DB_BACKUP=1 is set -- though that last one prints a loud warning so a
  # leaked env var cannot defeat the guard invisibly. Each snapshot is validated
  # (non-empty AND pg_restore --list shows restorable data items) before the
  # destructive task proceeds.
  class SafetyBackup
    SKIP_ENV = "SKIP_DB_BACKUP"
    # Rake tasks that destroy data via the DROP DATABASE path and therefore need
    # a pre-drop backup of the targeted env(s). Matched by exact name or prefix
    # so per-DB variants (db:drop:primary) and :all variants are caught. Tasks
    # that destroy via purge/truncate/load_schema are covered by the prepend hook
    # instead -- listing them here would wrongly snapshot the dev DB on every
    # db:test:prepare run.
    DROP_PATH_TASK_PREFIXES = %w[
      db:drop
      db:migrate:reset
      db:reset
    ].freeze
    SYSTEM_TABLES = %w[schema_migrations ar_internal_metadata].freeze
    MIN_DUMP_BYTES = 1024

    # Raised when a snapshot cannot be produced or verified, so callers can
    # distinguish a deliberate abort from any other RuntimeError.
    class BackupFailed < StandardError; end

    @assessed = Set.new # database names already decided about (avoids re-dumping AND re-ANALYZE)

    class << self
      attr_reader :assessed

      # Tests / explicit re-arm within a console session.
      def reset!
        @assessed = Set.new
        @skip_announced = false
      end

      # Rake-task-level guard (after_initialize). Backs up every database the
      # invoked drop-path task is about to destroy.
      def backup_before_destructive!
        return unless drop_path_task_invoked?

        if skipped?
          announce_skip!
          return
        end

        targeted_configs.each { |config| snapshot_if_populated!(config) }
      end

      # load_schema / purge / truncate_tables prepend hook. Snapshots the
      # specific database about to be destroyed, regardless of env.
      def snapshot_if_populated!(db_config)
        if skipped?
          announce_skip!
          return
        end

        database = db_config.respond_to?(:database) ? db_config.database : nil
        return if database.blank?
        return if assessed.include?(database)

        populated = populated?(db_config)
        assessed << database
        dump_database(db_config) if populated
      end

      private

      def skipped?
        Rails.env.production? || ci? || skip_env_set?
      end

      def ci?
        %w[1 true yes].include?(ENV["CI"]&.downcase)
      end

      def skip_env_set?
        %w[1 true yes].include?(ENV[SKIP_ENV]&.downcase)
      end

      # Announce (once per process) when the guard is bypassed via SKIP_DB_BACKUP.
      # CI/production skips are deliberate and stay silent.
      def announce_skip!
        return unless skip_env_set?
        return if @skip_announced

        @skip_announced = true
        warn "[db:safety] WARNING: #{SKIP_ENV}=1 is set -- destructive task will run WITHOUT a backup snapshot."
      end

      def drop_path_task_invoked?
        task_names.any? do |name|
          DROP_PATH_TASK_PREFIXES.any? { |prefix| name == prefix || name.start_with?("#{prefix}:") }
        end
      end

      def task_names
        ARGV + rake_top_level_tasks
      end

      def rake_top_level_tasks
        return [] unless defined?(Rake.application)

        Rake.application.top_level_tasks
      end

      # Databases the invoked task will destroy: every configured env for :all
      # variants, otherwise just the current env.
      def targeted_configs
        if task_names.any? { |name| name.end_with?(":all") }
          ActiveRecord::Base.configurations.configs_for.to_a
        else
          ActiveRecord::Base.configurations.configs_for(env_name: Rails.env.to_s)
        end
      end

      # A database counts as populated if it holds any rows outside the two
      # Rails bookkeeping tables. ANALYZE is run first so the planner estimate
      # reflects current data -- without it a freshly-restored or bulk-loaded
      # database can report stale (even zero) row counts until autovacuum
      # catches up, and we would skip the backup. ANALYZE runs once, right
      # before a destructive op; on dev-sized databases it is sub-second, and
      # correctness here matters far more than that cost.
      #
      # NOTE: deliberately does NOT short-circuit on a missing schema_migrations
      # table -- that is precisely the precondition under which Rails decides to
      # call load_schema, and the database can still hold real data.
      def populated?(db_config)
        with_connection(db_config) do |connection|
          connection.execute("ANALYZE")
          exclude = SYSTEM_TABLES.map { |t| connection.quote(t) }.join(", ")
          estimate = connection.select_value(<<~SQL.squish)
            SELECT COALESCE(sum(n_live_tup), 0) FROM pg_stat_user_tables
            WHERE relname NOT IN (#{exclude})
          SQL
          estimate.to_i.positive?
        end
      rescue ActiveRecord::NoDatabaseError
        # The only "safely empty" signal: the database genuinely does not exist.
        false
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid, PG::Error => e
        # Fail CLOSED. If we cannot prove the database is empty -- transient
        # connection blip, stats view revoked, statement timeout -- we must not
        # let the destructive task proceed. NoDatabaseError above is the only
        # case that safely maps to "nothing to back up"; everything else aborts.
        raise BackupFailed, "cannot assess whether #{db_config.database} has data to back up " \
                            "(#{e.class}); refusing to destroy without a snapshot. Set #{SKIP_ENV}=1 to override."
      end

      def dump_database(db_config)
        label = "#{db_config.name}/#{db_config.database}"
        basename = dump_basename(db_config)
        warn "[db:safety] Backing up #{label} -> #{basename} ..."
        unless system(dump_env(db_config), "bin/db-dump", basename, chdir: Rails.root)
          raise BackupFailed, "Snapshot of #{label} failed (bin/db-dump exited #{$?&.exitstatus}); aborting. " \
                              "Set #{SKIP_ENV}=1 to proceed WITHOUT a backup."
        end
        verify_dump!(label, File.join(Rails.root, "backups", basename))
      end

      def dump_basename(db_config)
        "#{db_config.database}_safety_#{Time.current.utc.strftime('%Y%m%d_%H%M%S')}.dump"
      end

      # Forward the full per-config connection details so bin/db-dump can dump
      # the right database without re-booting Rails (its DB_NAME-only fallback
      # shells out to `bin/rails runner`). PGOPTIONS bounds pg_dump per-statement
      # so a lock wait / stall aborts instead of hanging the destructive task.
      def dump_env(db_config)
        cfg = db_config.respond_to?(:configuration_hash) ? db_config.configuration_hash : {}
        {
          "DB_NAME" => cfg[:database].to_s,
          "DB_HOST" => cfg[:host].to_s,
          "DB_USER" => cfg[:username].to_s,
          "DB_PASSWORD" => cfg[:password].to_s,
          "PGOPTIONS" => "-c statement_timeout=#{ENV.fetch('DB_DUMP_STATEMENT_TIMEOUT_MS', '300_000')}"
        }
      end

      def verify_dump!(label, path)
        unless File.exist?(path) && File.size(path) > MIN_DUMP_BYTES
          raise BackupFailed, "Snapshot of #{label} is missing or empty (#{path}); aborting."
        end

        # Best-effort restorability check. If pg_restore is absent we fall back
        # to the size check above -- never false-abort for a missing tool.
        listing, status = Open3.capture2("pg_restore", "-l", path)
        return unless status.success?
        return if listing.scan(/TABLE DATA|SEQUENCE SET/).any?

        raise BackupFailed, "Snapshot of #{label} has no restorable data items (#{path}); aborting."
      rescue Errno::ENOENT
        # pg_restore not installed -- rely on the size check.
      end

      # Rails has no public API for a short-lived per-db_config connection pool.
      # This borrows a PRIVATE helper (ActiveRecord::Tasks::DatabaseTasks --
      # `with_temporary_pool`, marked :nodoc: in Rails 8.1). If a Rails upgrade
      # renames or removes it, populated? raises NoMethodError (NOT rescued
      # here), which aborts the destructive task loudly -- re-pin the helper
      # name rather than disabling the guard.
      def with_connection(db_config)
        ActiveRecord::Tasks::DatabaseTasks.send(:with_temporary_pool, db_config) do |pool|
          pool.with_connection { |connection| yield connection }
        end
      end
    end
  end
end
