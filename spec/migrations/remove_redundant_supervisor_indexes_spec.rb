# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128064551_remove_redundant_supervisor_indexes")

RSpec.describe RemoveRedundantSupervisorIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:retained) do
    {
      supervisor_incident_audits: {
        "index_supervisor_incident_audits_on_account_id" => [ :account_id ],
        "idx_on_supervisor_incident_id_occurred_at_1a4244e05f" => [ :supervisor_incident_id, :occurred_at ]
      },
      supervisor_incidents: {
        "index_supervisor_incidents_on_account_id_and_status" => [ :account_id, :status ],
        "index_supervisor_incidents_on_supervisor_snapshot_id" => [ :supervisor_snapshot_id ],
        "index_supervisor_incidents_on_account_and_fingerprint" => [ :account_id, :fingerprint ],
        "idx_on_account_id_retention_expires_at_06514e2ffe" => [ :account_id, :retention_expires_at ]
      },
      supervisor_snapshots: {
        "idx_on_account_id_retention_expires_at_c5e39567b6" => [ :account_id, :retention_expires_at ]
      }
    }
  end

  around do |example|
    schema = "pghero_supervisor_indexes_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      prepare_tables
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-023
  it "removes only redundant prefixes while preserving retained indexes and rows" do
    original = rows
    2.times { migration.up }

    retained.each do |table, definitions|
      expect(indexes(table)).to eq(definitions.transform_values { |columns| columns.map(&:to_s) })
    end
    expect(rows).to eq(original)
  end

  # @spec POSTGRESQL-PERSISTENCE-023
  it "restores the original indexes on repeated rollback without changing rows" do
    original_indexes = retained.keys.to_h { |table| [ table, indexes(table) ] }
    original_rows = rows
    migration.up
    2.times { migration.down }

    expect(retained.keys.to_h { |table| [ table, indexes(table) ] }).to eq(original_indexes)
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-023
  it "preserves account-scoped incident fingerprint uniqueness" do
    migration.up

    expect do
      connection.execute("INSERT INTO supervisor_incidents (account_id, fingerprint) VALUES (1, 'fixture')")
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect do
      connection.execute("INSERT INTO supervisor_incidents (account_id, fingerprint) VALUES (2, 'fixture')")
    end.not_to raise_error
  end

  # @spec POSTGRESQL-PERSISTENCE-023
  it "retains usable audit, incident status and snapshot retention index paths" do
    migration.up
    queries = {
      "supervisor_incident_audits WHERE supervisor_incident_id = 1" => "idx_on_supervisor_incident_id_occurred_at_1a4244e05f",
      "supervisor_incidents WHERE account_id = 1 AND status = 'open'" => "index_supervisor_incidents_on_account_id_and_status",
      "supervisor_snapshots WHERE account_id = 1 AND retention_expires_at < '2027-01-01'" => "idx_on_account_id_retention_expires_at_c5e39567b6"
    }
    queries.each do |query, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM #{query}")
      end
      expect(plan).to include(index)
    end
  end

  def indexes(table)
    connection.indexes(table).to_h { |index| [ index.name, index.columns ] }
  end

  def rows
    retained.keys.to_h { |table| [ table, connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ] }
  end

  def prepare_tables
    connection.create_table(:supervisor_incident_audits) do |t|
      t.bigint :account_id
      t.bigint :supervisor_incident_id
      t.timestamp :occurred_at
    end
    connection.create_table(:supervisor_incidents) do |t|
      t.bigint :account_id
      t.bigint :supervisor_snapshot_id
      t.string :status
      t.string :fingerprint
      t.timestamp :retention_expires_at
    end
    connection.create_table(:supervisor_snapshots) do |t|
      t.bigint :account_id
      t.timestamp :retention_expires_at
    end
    retained.each do |table, definitions|
      definitions.each do |name, columns|
        connection.add_index table, columns, name: name, unique: name == "index_supervisor_incidents_on_account_and_fingerprint"
      end
    end
    connection.add_index :supervisor_incident_audits, :supervisor_incident_id
    connection.add_index :supervisor_incidents, :account_id
    connection.add_index :supervisor_snapshots, :account_id
    connection.execute("INSERT INTO supervisor_incident_audits (account_id, supervisor_incident_id, occurred_at) VALUES (1, 1, '2026-11-01')")
    connection.execute("INSERT INTO supervisor_incidents (account_id, status, fingerprint, retention_expires_at) VALUES (1, 'open', 'fixture', '2026-12-01')")
    connection.execute("INSERT INTO supervisor_snapshots (account_id, retention_expires_at) VALUES (1, '2026-12-01')")
  end
end
