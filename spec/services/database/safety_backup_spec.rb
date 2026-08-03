# frozen_string_literal: true

require "rails_helper"

RSpec.describe Database::SafetyBackup do
  let(:primary) do
    instance_double(
      ActiveRecord::DatabaseConfigurations::HashConfig,
      database: "paid_development", name: "primary",
      configuration_hash: { database: "paid_development", host: "postgres", username: "paid", password: "paid" }
    )
  end
  let(:empty_db) do
    instance_double(
      ActiveRecord::DatabaseConfigurations::HashConfig,
      database: "paid_fresh", name: "fresh",
      configuration_hash: { database: "paid_fresh", host: "postgres", username: "paid", password: "paid" }
    )
  end

  around do |example|
    described_class.reset!
    original_argv = ARGV.dup
    ARGV.replace([])
    original_skip = ENV.delete(Database::SafetyBackup::SKIP_ENV)
    original_ci = ENV.delete("CI")
    example.run
  ensure
    described_class.reset!
    ARGV.replace(original_argv)
    ENV[described_class::SKIP_ENV] = original_skip if described_class.respond_to?(:SKIP_ENV)
    ENV["CI"] = original_ci
  end

  before do
    allow(described_class).to receive_messages(
      targeted_configs: [ primary, empty_db ],
      rake_top_level_tasks: []
    )
    allow(described_class).to receive(:dump_database).and_call_original
  end

  describe ".populated?" do
    let(:connection) do
      instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).tap do |c|
        allow(c).to receive(:quote).and_return("'x'")
      end
    end

    before { allow(described_class).to receive(:with_connection).and_yield(connection) }

    it "runs ANALYZE and returns true when non-bookkeeping tables have rows" do
      expect(connection).to receive(:execute).with("ANALYZE")
      allow(connection).to receive(:select_value).and_return(1234)

      expect(described_class.send(:populated?, primary)).to be true
    end

    it "returns false when there is no data outside schema_migrations/ar_internal_metadata" do
      allow(connection).to receive(:execute).with("ANALYZE")
      allow(connection).to receive(:select_value).and_return(0)

      expect(described_class.send(:populated?, primary)).to be false
    end

    it "returns false when the database genuinely does not exist" do
      allow(described_class).to receive(:with_connection).and_raise(ActiveRecord::NoDatabaseError)

      expect(described_class.send(:populated?, primary)).to be false
    end

    it "fails closed when a transient connection error prevents assessment" do
      allow(described_class).to receive(:with_connection).and_raise(PG::Error)

      expect { described_class.send(:populated?, primary) }
        .to raise_error(described_class::BackupFailed, /refusing to destroy/)
    end
  end

  describe "drop-path task detection" do
    it "fires for the destructive drop-path tasks and their per-DB/:all variants" do
      %w[db:reset db:drop db:drop:primary db:drop:all db:migrate:reset db:reset:cable].each do |task|
        ARGV.replace([ task ])
        expect(described_class.send(:drop_path_task_invoked?)).to be(true), task
      end
    end

    it "does NOT fire for tasks the prepend hook covers, or for harmless tasks" do
      %w[db:migrate db:seed db:purge db:truncate_all db:schema:load db:test:prepare console runner].each do |task|
        ARGV.replace([ task ])
        expect(described_class.send(:drop_path_task_invoked?)).to be(false), task
      end
    end
  end

  describe ".backup_before_destructive!" do
    it "snapshots populated databases when a drop-path task is invoked" do
      ARGV.replace([ "db:reset" ])
      allow(described_class).to receive(:populated?).with(primary).and_return(true)
      allow(described_class).to receive(:populated?).with(empty_db).and_return(false)
      expect(described_class).to receive(:dump_database).with(primary).and_return(true)

      described_class.backup_before_destructive!
    end

    it "aborts (propagates BackupFailed) when a snapshot fails, so db:reset never proceeds" do
      ARGV.replace([ "db:reset" ])
      allow(described_class).to receive(:populated?).with(primary).and_return(true)
      allow(described_class).to receive(:populated?).with(empty_db).and_return(false)
      allow(described_class).to receive(:dump_database).with(primary)
        .and_raise(described_class::BackupFailed, "Snapshot of primary/paid_development failed")

      expect { described_class.backup_before_destructive! }
        .to raise_error(described_class::BackupFailed, /Snapshot.*failed/)
    end
  end

  describe ".snapshot_if_populated!" do
    it "backs up a populated database and records the decision" do
      allow(described_class).to receive(:populated?).with(primary).and_return(true)
      allow(described_class).to receive(:dump_database).with(primary).and_return(true)

      described_class.snapshot_if_populated!(primary)

      expect(described_class.assessed).to include("paid_development")
    end

    it "skips a non-populated database without dumping" do
      allow(described_class).to receive(:populated?).with(empty_db).and_return(false)

      described_class.snapshot_if_populated!(empty_db)

      expect(described_class.assessed).to include("paid_fresh")
      expect(described_class).not_to have_received(:dump_database)
    end

    it "skips a config with a blank database name" do
      blank = instance_double(ActiveRecord::DatabaseConfigurations::HashConfig, database: nil)

      described_class.snapshot_if_populated!(blank)

      expect(described_class.assessed).to be_empty
      expect(described_class).not_to have_received(:dump_database)
    end

    it "does not re-assess or re-dump the same database within one process" do
      allow(described_class).to receive(:populated?).with(primary).and_return(true)
      expect(described_class).to receive(:dump_database).with(primary).once.and_return(true)

      3.times { described_class.snapshot_if_populated!(primary) }
    end

    it "does not double-back-up across the rake entry point and the prepend hook" do
      ARGV.replace([ "db:reset" ])
      allow(described_class).to receive(:populated?).with(primary).and_return(true)
      allow(described_class).to receive(:populated?).with(empty_db).and_return(false)
      expect(described_class).to receive(:dump_database).with(primary).once.and_return(true)

      described_class.backup_before_destructive!        # rake-level: dumps primary
      described_class.snapshot_if_populated!(primary)   # load_schema hook fires next: skip
    end

    it "aborts when the underlying dump fails" do
      allow(described_class).to receive(:populated?).with(primary).and_return(true)
      allow(described_class).to receive(:system).and_return(nil)

      expect { described_class.snapshot_if_populated!(primary) }
        .to raise_error(described_class::BackupFailed, /Snapshot.*failed/)
    end
  end

  describe ".dump_env" do
    it "uses a PostgreSQL-compatible statement timeout value" do
      env = described_class.send(:dump_env, primary)

      expect(env.fetch("PGOPTIONS")).to eq("-c statement_timeout=300000")
    end
  end

  describe "skip conditions" do
    it "is skipped in production" do
      allow(Rails.env).to receive(:production?).and_return(true)

      described_class.snapshot_if_populated!(primary)

      expect(described_class.assessed).to be_empty
    end

    it "is skipped when CI is set" do
      ENV["CI"] = "true"
      allow(described_class).to receive(:populated?).with(primary).and_return(true)

      described_class.snapshot_if_populated!(primary)

      expect(described_class.assessed).to be_empty
      expect(described_class).not_to have_received(:dump_database)
    end

    it "accepts CI=1 / CI=yes as well as CI=true" do
      %w[1 yes true].each do |value|
        described_class.reset!
        ENV["CI"] = value
        expect(described_class.send(:ci?)).to be(true), "CI=#{value}"
      end
    end

    it "warns loudly when SKIP_DB_BACKUP bypasses the guard during a destructive call" do
      ENV[described_class::SKIP_ENV] = "1"
      expect { described_class.snapshot_if_populated!(primary) }
        .to output(/WARNING.*SKIP_DB_BACKUP.*WITHOUT a backup/).to_stderr

      expect(described_class).not_to have_received(:dump_database)
    end
  end

  it "defines BackupFailed as a rescuable StandardError" do
    expect(Database::SafetyBackup::BackupFailed).to be < StandardError
  end

  describe "wiring (config/initializers/database_safety_backup.rb)" do
    # Guards the silent-detach regression the initializer's own comment warns
    # about: if the hook ever stops being prepended, destructive ops run
    # unguarded with a fully-green unit suite.
    it "prepends DatabaseSafetyBackupHook onto ActiveRecord::Tasks::DatabaseTasks" do
      expect(ActiveRecord::Tasks::DatabaseTasks.ancestors)
        .to include(DatabaseSafetyBackupHook)
    end

    it "intercepts load_schema, purge, and truncate_tables before the original" do
      tasks = ActiveRecord::Tasks::DatabaseTasks
      [ :load_schema, :purge, :truncate_tables ].each do |method|
        expect(tasks.instance_method(method).owner).to eq(DatabaseSafetyBackupHook), "#{method} not hooked"
      end
    end
  end
end
