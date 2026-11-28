# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128091208_remove_redundant_quality_event_project_indexes")

RSpec.describe RemoveRedundantQualityEventProjectIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:tables) { %i[quality_gate_events quality_pause_events quality_recovery_actions] }
  let(:removed_names) { tables.map { |table| "index_#{table}_on_project_id" } }

  around do |example|
    schema = "pghero_quality_events_#{SecureRandom.hex(6)}"
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

  # @spec POSTGRESQL-PERSISTENCE-027
  it "removes only the three project prefixes while preserving all other indexes and event data" do
    original_indexes = indexes
    original_rows = rows
    2.times { migration.up }

    expect(indexes).to eq(original_indexes.transform_values { |definitions| definitions.except(*removed_names) })
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-027
  it "restores exact original definitions and rows on repeated rollback" do
    original_indexes = indexes
    original_rows = rows
    migration.up
    2.times { migration.down }

    expect(indexes).to eq(original_indexes)
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-027
  it "retains usable project gate, pause-history and recovery-history paths" do
    migration.up
    queries = {
      "quality_gate_events WHERE project_id = 1 AND event_type = 'trigger' ORDER BY created_at DESC" => "idx_quality_gate_events_project_type_time",
      "quality_pause_events WHERE project_id = 1 ORDER BY created_at DESC" => "index_quality_pause_events_on_project_id_and_created_at",
      "quality_recovery_actions WHERE project_id = 1 ORDER BY created_at DESC" => "index_quality_recovery_actions_on_project_id_and_created_at"
    }
    queries.each do |query, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM #{query}")
      end
      expect(plan).to include(index)
    end
  end

  def indexes
    tables.to_h do |table|
      [ table, connection.indexes(table).to_h { |index| [ index.name, [ index.columns, index.unique, index.where, index.valid? ] ] } ]
    end
  end

  def rows
    tables.to_h { |table| [ table, connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ] }
  end

  def prepare_tables
    connection.create_table(:quality_gate_events) do |t|
      %i[project_id quality_metric_id quality_threshold_id].each { |column| t.bigint column }
      t.string :event_type
      t.decimal :score_value, precision: 5, scale: 4
      t.jsonb :metadata, default: {}
      t.timestamp :created_at
    end
    connection.create_table(:quality_pause_events) do |t|
      %i[project_id agent_run_id].each { |column| t.bigint column }
      t.string :event_type
      t.jsonb :metadata, default: {}
      t.timestamp :created_at
    end
    connection.create_table(:quality_recovery_actions) do |t|
      %i[project_id agent_run_id prompt_version_id].each { |column| t.bigint column }
      %i[action_type status].each { |column| t.string column }
      t.jsonb :result, default: {}
      t.timestamp :created_at
    end
    tables.each { |table| connection.add_index table, :project_id }
    %i[quality_metric_id quality_threshold_id].each { |column| connection.add_index :quality_gate_events, column }
    connection.add_index :quality_gate_events, %i[project_id event_type created_at], name: "idx_quality_gate_events_project_type_time"
    connection.add_index :quality_pause_events, :agent_run_id
    connection.add_index :quality_pause_events, %i[project_id created_at]
    %i[action_type agent_run_id prompt_version_id status].each { |column| connection.add_index :quality_recovery_actions, column }
    connection.add_index :quality_recovery_actions, %i[project_id created_at]
    connection.execute("INSERT INTO quality_gate_events (project_id, event_type, score_value, metadata, created_at) VALUES (1, 'trigger', 0.4, '{\"gate\":\"failed\"}', '2026-11-28')")
    connection.execute("INSERT INTO quality_pause_events (project_id, event_type, metadata, created_at) VALUES (1, 'paused', '{\"reason\":\"quality\"}', '2026-11-28')")
    connection.execute("INSERT INTO quality_recovery_actions (project_id, action_type, status, result, created_at) VALUES (1, 'prompt_rollback', 'executed', '{\"recovered\":true}', '2026-11-28')")
  end
end
