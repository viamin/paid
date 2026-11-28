# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128050820_remove_redundant_style_guide_exposure_indexes")

RSpec.describe RemoveRedundantStyleGuideExposureIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:covering_indexes) do
    {
      "index_style_guide_run_exposures_on_run_and_name" => [ :agent_run_id, :guide_name ],
      "idx_on_style_guide_ab_test_assignment_id_d2bca3fb4e" => [ :style_guide_ab_test_assignment_id ],
      "idx_on_style_guide_id_created_at_4675f78c23" => [ :style_guide_id, :created_at ],
      "index_style_guide_run_exposures_on_style_guide_version_id" => [ :style_guide_version_id ]
    }
  end

  around do |example|
    schema = "pghero_exposure_indexes_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      prepare_exposure_table
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-017
  it "removes three duplicates while retaining compound indexes and exposure rows" do
    original_rows = connection.select_all("SELECT * FROM style_guide_run_exposures").to_a

    2.times { migration.up }

    expect(indexes).to eq(covering_indexes.transform_values { |columns| columns.map(&:to_s) })
    expect(connection.select_all("SELECT * FROM style_guide_run_exposures").to_a).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-017
  it "restores each single-column index on rollback without dropping its coverer" do
    migration.up
    2.times { migration.down }

    expect(indexes).to eq(covering_indexes.transform_values { |columns| columns.map(&:to_s) }.merge(
      "index_style_guide_run_exposures_on_agent_run_id" => [ "agent_run_id" ],
      "index_style_guide_run_exposures_on_assignment_id" => [ "style_guide_ab_test_assignment_id" ],
      "index_style_guide_run_exposures_on_style_guide_id" => [ "style_guide_id" ]))
    expect(connection.select_value("SELECT count(*) FROM style_guide_run_exposures")).to eq(1)
  end

  # @spec POSTGRESQL-PERSISTENCE-017
  it "retains usable index paths for run, assignment and guide lookups" do
    migration.up

    { "agent_run_id" => "index_style_guide_run_exposures_on_run_and_name",
      "style_guide_ab_test_assignment_id" => "idx_on_style_guide_ab_test_assignment_id_d2bca3fb4e",
      "style_guide_id" => "idx_on_style_guide_id_created_at_4675f78c23" }.each do |column, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM style_guide_run_exposures WHERE #{column} = 1")
      end
      expect(plan).to include(index)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-017
  it "continues to reject duplicate run/name exposures after removing the prefix indexes" do
    migration.up

    expect do
      connection.execute("INSERT INTO style_guide_run_exposures (agent_run_id, guide_name) VALUES (1, 'guide')")
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  def indexes
    connection.indexes(:style_guide_run_exposures).to_h { |index| [ index.name, index.columns ] }
  end

  def prepare_exposure_table
    connection.create_table(:style_guide_run_exposures) do |table|
      table.bigint :agent_run_id
      table.bigint :style_guide_ab_test_assignment_id
      table.bigint :style_guide_id
      table.bigint :style_guide_version_id
      table.string :guide_name
      table.timestamp :created_at
    end
    covering_indexes.each do |name, columns|
      connection.add_index :style_guide_run_exposures, columns, name: name,
        unique: name == "index_style_guide_run_exposures_on_run_and_name"
    end
    connection.add_index :style_guide_run_exposures, :agent_run_id
    connection.add_index :style_guide_run_exposures, :style_guide_id
    connection.add_index :style_guide_run_exposures, :style_guide_ab_test_assignment_id,
      name: "index_style_guide_run_exposures_on_assignment_id"
    connection.execute("INSERT INTO style_guide_run_exposures (agent_run_id, guide_name) VALUES (1, 'guide')")
  end
end
