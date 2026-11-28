# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128070122_remove_redundant_work_item_execution_indexes")

RSpec.describe RemoveRedundantWorkItemExecutionIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:retained_indexes) do
    {
      work_item_assignments: {
        "index_work_item_assignments_on_account_id" => [ :account_id ],
        "index_work_item_assignments_on_work_item_project_mapping_id" => [ :work_item_project_mapping_id ],
        "index_work_item_assignments_on_assigned_by_id" => [ :assigned_by_id ],
        "index_work_item_assignments_on_work_item_and_project" => [ :work_item_id, :project_id ],
        "index_work_item_assignments_on_project_and_work_item" => [ :project_id, :work_item_id ]
      },
      work_item_continuation_grants: {
        "index_work_item_continuation_grants_on_created_by_id" => [ :created_by_id ],
        "index_work_item_continuation_grants_on_revoked_by_id" => [ :revoked_by_id ],
        "index_continuation_grants_work_item_endpoint" => [ :project_id, :issue_id, :endpoint ],
        "index_continuation_grants_active_lookup" => [ :issue_id, :revoked_at, :completed_at ]
      }
    }
  end

  around do |example|
    schema = "pghero_work_execution_#{SecureRandom.hex(6)}"
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

  # @spec POSTGRESQL-PERSISTENCE-024
  it "removes only the four redundant prefixes while preserving retained indexes and rows" do
    original = rows
    2.times { migration.up }

    retained_indexes.each do |table, definitions|
      expect(connection.indexes(table).map(&:name)).to match_array(definitions.keys)
    end
    expect(rows).to eq(original)
  end

  # @spec POSTGRESQL-PERSISTENCE-024
  it "restores original indexes on repeated rollback without changing rows" do
    original = retained_indexes.keys.to_h { |table| [ table, connection.indexes(table).map(&:name).sort ] }
    original_rows = rows
    migration.up
    2.times { migration.down }

    expect(retained_indexes.keys.to_h { |table| [ table, connection.indexes(table).map(&:name).sort ] }).to eq(original)
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-024
  it "preserves assignment uniqueness across both lookup directions" do
    migration.up

    expect do
      connection.execute("INSERT INTO work_item_assignments (work_item_id, project_id) VALUES (1, 1)")
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect do
      connection.execute("INSERT INTO work_item_assignments (work_item_id, project_id) VALUES (1, 2)")
    end.not_to raise_error
  end

  # @spec POSTGRESQL-PERSISTENCE-024
  it "preserves active, revoked and completed grant selection" do
    migration.up

    active = connection.select_values("SELECT issue_id FROM work_item_continuation_grants WHERE revoked_at IS NULL AND completed_at IS NULL ORDER BY issue_id")
    expect(active).to eq([ 1 ])
    expect(connection.select_value("SELECT COUNT(*) FROM work_item_continuation_grants")).to eq(3)
  end

  # @spec POSTGRESQL-PERSISTENCE-024
  it "retains usable assignment and continuation lookup paths" do
    migration.up
    queries = {
      "work_item_assignments WHERE project_id = 1" => "index_work_item_assignments_on_project_and_work_item",
      "work_item_assignments WHERE work_item_id = 1" => "index_work_item_assignments_on_work_item_and_project",
      "work_item_continuation_grants WHERE project_id = 1" => "index_continuation_grants_work_item_endpoint",
      "work_item_continuation_grants WHERE issue_id = 1 AND revoked_at IS NULL AND completed_at IS NULL" => "index_continuation_grants_active_lookup"
    }
    queries.each do |query, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM #{query}")
      end
      expect(plan).to include(index)
    end
  end

  def rows
    retained_indexes.keys.to_h { |table| [ table, connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ] }
  end

  def prepare_tables
    connection.create_table(:work_item_assignments) do |t|
      %i[account_id work_item_id project_id work_item_project_mapping_id assigned_by_id].each { |column| t.bigint column }
    end
    connection.create_table(:work_item_continuation_grants) do |t|
      %i[project_id issue_id created_by_id revoked_by_id].each { |column| t.bigint column }
      t.string :endpoint
      t.timestamp :revoked_at
      t.timestamp :completed_at
    end
    retained_indexes.each do |table, definitions|
      definitions.each do |name, columns|
        connection.add_index table, columns, name: name, unique: name == "index_work_item_assignments_on_work_item_and_project"
      end
    end
    %i[project_id work_item_id].each { |column| connection.add_index :work_item_assignments, column }
    %i[project_id issue_id].each { |column| connection.add_index :work_item_continuation_grants, column }
    connection.execute("INSERT INTO work_item_assignments (account_id, work_item_id, project_id) VALUES (1, 1, 1), (2, 2, 2)")
    connection.execute(<<~SQL)
      INSERT INTO work_item_continuation_grants (project_id, issue_id, endpoint, revoked_at, completed_at)
      VALUES (1, 1, 'create_pr', NULL, NULL), (1, 2, 'create_pr', '2026-11-01', NULL), (2, 3, 'create_pr', NULL, '2026-11-01')
    SQL
  end
end
