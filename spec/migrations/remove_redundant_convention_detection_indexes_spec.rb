# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128051941_remove_redundant_convention_detection_indexes")

RSpec.describe RemoveRedundantConventionDetectionIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:covering_indexes) do
    {
      "index_project_convention_detections_on_project_id_and_key" => [ :project_id, :key ],
      "idx_project_convention_detections_unique_detector" => [ :project_version_id, :key, :detector_key ]
    }
  end

  around do |example|
    schema = "pghero_detection_indexes_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      prepare_detection_table
      prepare_override_and_recommendation_tables
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "removes both duplicates while retaining compound indexes and detection rows" do
    original_rows = connection.select_all("SELECT * FROM project_convention_detections").to_a

    2.times { migration.up }

    expect(indexes).to eq(covering_indexes.transform_values { |columns| columns.map(&:to_s) })
    expect(connection.select_all("SELECT * FROM project_convention_detections").to_a).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "restores each single-column index on rollback without dropping its coverer" do
    migration.up
    2.times { migration.down }

    expect(indexes).to eq(covering_indexes.transform_values { |columns| columns.map(&:to_s) }.merge(
      "index_project_convention_detections_on_project_version_id" => [ "project_version_id" ],
      "index_project_convention_detections_on_project_id" => [ "project_id" ]))
    expect(connection.select_value("SELECT count(*) FROM project_convention_detections")).to eq(1)
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "retains usable index paths for project and version lookups" do
    migration.up

    { "project_id" => "index_project_convention_detections_on_project_id_and_key",
      "project_version_id" => "idx_project_convention_detections_unique_detector" }.each do |column, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM project_convention_detections WHERE #{column} = 1")
      end
      expect(plan).to include(index)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "continues to reject duplicate version/key/detector findings after removing the prefix indexes" do
    migration.up

    expect do
      connection.execute("INSERT INTO project_convention_detections (project_version_id, project_id, key, detector_key) VALUES (1, 2, 'language', 'detector')")
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "removes override and recommendation prefixes while preserving other definitions and rows" do
    before_indexes = related_indexes
    before_rows = related_rows
    2.times { migration.up }

    expect(related_indexes).to eq(before_indexes.transform_values do |definitions|
      definitions.except("index_project_convention_overrides_on_project_id", "index_project_convention_recommendations_on_project_id")
    end)
    expect(related_rows).to eq(before_rows)
    2.times { migration.down }
    expect(related_indexes).to eq(before_indexes)
    expect(related_rows).to eq(before_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "preserves override identity and pending recommendation uniqueness" do
    migration.up

    expect do
      connection.execute("INSERT INTO project_convention_overrides (project_id, key) VALUES (1, 'language')")
    end.to raise_error(ActiveRecord::RecordNotUnique)
    duplicate = "INSERT INTO project_convention_recommendations (project_id, convention_key, action_type, status) VALUES (1, 'language', 'open_pr', 'pending')"
    expect { connection.execute(duplicate) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { connection.execute(duplicate.sub("'pending'", "'dismissed'")) }.not_to raise_error
    expect { connection.execute(duplicate.sub("VALUES (1,", "VALUES (2,")) }.not_to raise_error
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "retains override and recommendation lookup paths" do
    migration.up
    queries = {
      "project_convention_overrides WHERE project_id = 1 AND key = 'language'" => "index_project_convention_overrides_on_project_id_and_key",
      "project_convention_recommendations WHERE project_id = 1 AND status = 'dismissed'" => "index_convention_recs_on_project_status"
    }
    queries.each do |query, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM #{query}")
      end
      expect(plan).to include(index)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "refuses removal when the override covering index is missing" do
    connection.remove_index :project_convention_overrides, name: "index_project_convention_overrides_on_project_id_and_key"
    before_indexes = related_indexes

    expect { migration.up }.to raise_error(ActiveRecord::IrreversibleMigration, /override covering index/)
    expect(related_indexes).to eq(before_indexes)
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "refuses removal when the override covering index no longer enforces uniqueness" do
    connection.remove_index :project_convention_overrides, name: "index_project_convention_overrides_on_project_id_and_key"
    connection.add_index :project_convention_overrides, %i[project_id key]
    before_indexes = related_indexes

    expect { migration.up }.to raise_error(ActiveRecord::IrreversibleMigration, /override covering index/)
    expect(related_indexes).to eq(before_indexes)
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "refuses a partial override coverer that excludes some project lookups" do
    connection.remove_index :project_convention_overrides, name: "index_project_convention_overrides_on_project_id_and_key"
    connection.add_index :project_convention_overrides, %i[project_id key], unique: true, where: "project_id = 1"

    expect { migration.up }.to raise_error(ActiveRecord::IrreversibleMigration, /override covering index/)
    expect(connection.index_exists?(:project_convention_overrides, name: "index_project_convention_overrides_on_project_id")).to be true
  end

  # @spec POSTGRESQL-PERSISTENCE-018
  it "refuses an invalid unique override coverer left by a failed concurrent build" do
    connection.remove_index :project_convention_overrides, name: "index_project_convention_overrides_on_project_id_and_key"
    connection.execute("INSERT INTO project_convention_overrides (project_id, key) VALUES (1, 'language')")
    expect do
      connection.add_index :project_convention_overrides, %i[project_id key], unique: true, algorithm: :concurrently
    end.to raise_error(ActiveRecord::RecordNotUnique)
    coverer = connection.indexes(:project_convention_overrides).find { |index| index.name == "index_project_convention_overrides_on_project_id_and_key" }
    expect(coverer.valid?).to be false

    expect { migration.up }.to raise_error(ActiveRecord::IrreversibleMigration, /override covering index/)
    expect(connection.index_exists?(:project_convention_overrides, name: "index_project_convention_overrides_on_project_id")).to be true
  end

  def related_indexes
    %i[project_convention_overrides project_convention_recommendations].to_h do |table|
      [ table, connection.indexes(table).to_h { |index| [ index.name, [ index.columns, index.unique, index.where ] ] } ]
    end
  end

  def related_rows
    %i[project_convention_overrides project_convention_recommendations].to_h do |table|
      [ table, connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ]
    end
  end

  def prepare_override_and_recommendation_tables
    connection.create_table(:project_convention_overrides) do |t|
      t.bigint :project_id
      t.string :key
    end
    connection.add_index :project_convention_overrides, :project_id
    connection.add_index :project_convention_overrides, %i[project_id key], unique: true
    connection.create_table(:project_convention_recommendations) do |t|
      %i[project_id applied_by_id dismissed_by_id].each { |column| t.bigint column }
      %i[convention_key action_type status].each { |column| t.string column }
    end
    %i[project_id applied_by_id dismissed_by_id].each do |column|
      connection.add_index :project_convention_recommendations, column
    end
    connection.add_index :project_convention_recommendations, %i[project_id status], name: "index_convention_recs_on_project_status"
    connection.add_index :project_convention_recommendations, %i[project_id convention_key action_type],
      unique: true, where: "status = 'pending'", name: "index_convention_recs_on_project_key_action"
    connection.execute("INSERT INTO project_convention_overrides (project_id, key) VALUES (1, 'language')")
    connection.execute("INSERT INTO project_convention_recommendations (project_id, convention_key, action_type, status) VALUES (1, 'language', 'open_pr', 'pending')")
  end

  def indexes
    connection.indexes(:project_convention_detections).to_h { |index| [ index.name, index.columns ] }
  end

  def prepare_detection_table
    connection.create_table(:project_convention_detections) do |table|
      table.bigint :project_version_id
      table.bigint :project_id
      table.string :key
      table.string :detector_key
    end
    covering_indexes.each do |name, columns|
      connection.add_index :project_convention_detections, columns, name: name, unique: columns.first == :project_version_id
    end
    %i[project_version_id project_id].each { |column| connection.add_index :project_convention_detections, column }
    connection.execute("INSERT INTO project_convention_detections (project_version_id, project_id, key, detector_key) VALUES (1, 2, 'language', 'detector')")
  end
end
