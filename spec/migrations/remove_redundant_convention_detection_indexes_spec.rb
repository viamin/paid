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
