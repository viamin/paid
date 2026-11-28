# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128044632_remove_redundant_staged_closeout_mapping_indexes")

RSpec.describe RemoveRedundantStagedCloseoutMappingIndexes do
  self.use_transactional_tests = false

  # @spec POSTGRESQL-PERSISTENCE-014
  it "preserves rows, covering indexes and revision uniqueness through removal and rollback" do
    with_mapping_schema do |connection|
      prepare_mapping_table(connection)
      rows = connection.select_all("SELECT * FROM staged_closeout_mappings").to_a
      retained = connection.indexes(:staged_closeout_mappings).reject { |index| index.columns.one? }.map(&:name)
      migration = described_class.new

      migration.up
      migration.up

      expect(connection.indexes(:staged_closeout_mappings).map(&:name)).to match_array(retained)
      expect(connection.select_all("SELECT * FROM staged_closeout_mappings").to_a).to eq(rows)
      expect do
        connection.execute("INSERT INTO staged_closeout_mappings (issue_id, project_id, criterion_key, revision) VALUES (1, 2, 'check', 1)")
      end.to raise_error(ActiveRecord::RecordNotUnique)

      migration.down
      migration.down

      expect(connection.indexes(:staged_closeout_mappings).map(&:name)).to match_array(retained +
        %w[index_staged_closeout_mappings_on_issue_id index_staged_closeout_mappings_on_project_id])
      expect(connection.select_all("SELECT * FROM staged_closeout_mappings").to_a).to eq(rows)
    end
  end

  def with_mapping_schema
    connection = ActiveRecord::Base.connection
    schema = "pghero_mapping_indexes_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      yield connection
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  def prepare_mapping_table(connection)
    connection.create_table(:staged_closeout_mappings) do |table|
      table.bigint :issue_id
      table.bigint :project_id
      table.string :criterion_key
      table.integer :revision
      table.string :status
    end
    connection.add_index :staged_closeout_mappings, [ :issue_id, :criterion_key, :revision ], unique: true,
      name: "index_staged_closeout_mapping_revisions"
    connection.add_index :staged_closeout_mappings, [ :project_id, :status ]
    connection.add_index :staged_closeout_mappings, :issue_id
    connection.add_index :staged_closeout_mappings, :project_id
    connection.execute("INSERT INTO staged_closeout_mappings (issue_id, project_id, criterion_key, revision, status) VALUES (1, 2, 'check', 1, 'approved')")
  end
end
