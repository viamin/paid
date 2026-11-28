# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128063629_remove_redundant_strategy_indexes")

RSpec.describe RemoveRedundantStrategyIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    schema = "pghero_strategy_indexes_#{SecureRandom.hex(6)}"
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

  # @spec POSTGRESQL-PERSISTENCE-021
  it "removes only the two redundant prefixes and preserves stored rows" do
    original = rows
    2.times { migration.up }

    expect(connection.indexes(:strategies).map(&:name)).to contain_exactly("index_strategies_on_decision_type_and_status")
    expect(connection.indexes(:strategy_versions).map(&:name)).to contain_exactly(
      "index_strategy_versions_on_strategy_id_and_version", "index_strategy_versions_one_active_per_strategy")
    expect(rows).to eq(original)
  end

  # @spec POSTGRESQL-PERSISTENCE-021
  it "restores both original indexes on repeated rollback without changing rows" do
    original = rows
    migration.up
    2.times { migration.down }

    expect(connection.index_exists?(:strategies, :decision_type)).to be(true)
    expect(connection.index_exists?(:strategy_versions, :strategy_id)).to be(true)
    expect(rows).to eq(original)
  end

  # @spec POSTGRESQL-PERSISTENCE-021
  it "preserves version and active-version uniqueness" do
    migration.up

    expect do
      connection.execute("INSERT INTO strategy_versions (strategy_id, version, promotion_state) VALUES (1, 1, 'draft')")
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect do
      connection.execute("INSERT INTO strategy_versions (strategy_id, version, promotion_state) VALUES (1, 2, 'active')")
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # @spec POSTGRESQL-PERSISTENCE-021
  it "retains usable index paths for decision and version lookups" do
    migration.up
    { "strategies WHERE decision_type = 'auto_pick'" => "index_strategies_on_decision_type_and_status",
      "strategy_versions WHERE strategy_id = 1" => "index_strategy_versions_on_strategy_id_and_version" }.each do |query, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM #{query}")
      end
      expect(plan).to include(index)
    end
  end

  def rows
    %w[strategies strategy_versions].to_h do |table|
      [ table, connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ]
    end
  end

  def prepare_tables
    connection.create_table(:strategies) { |t| t.string :decision_type; t.string :status }
    connection.add_index :strategies, :decision_type
    connection.add_index :strategies, [ :decision_type, :status ]
    connection.create_table(:strategy_versions) do |t|
      t.bigint :strategy_id
      t.integer :version
      t.string :promotion_state
      t.timestamp :retired_at
    end
    connection.add_index :strategy_versions, :strategy_id
    connection.add_index :strategy_versions, [ :strategy_id, :version ], unique: true
    connection.add_index :strategy_versions, :strategy_id, unique: true,
      where: "promotion_state = 'active' AND retired_at IS NULL", name: "index_strategy_versions_one_active_per_strategy"
    connection.execute("INSERT INTO strategies (decision_type, status) VALUES ('auto_pick', 'active')")
    connection.execute("INSERT INTO strategy_versions (strategy_id, version, promotion_state) VALUES (1, 1, 'active')")
  end
end
