# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128045923_remove_redundant_project_membership_indexes")

RSpec.describe RemoveRedundantProjectMembershipIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:covering_indexes) do
    {
      "index_project_memberships_on_project_id_and_role" => [ :project_id, :role ],
      "index_project_memberships_on_user_id_and_project_id" => [ :user_id, :project_id ]
    }
  end

  around do |example|
    schema = "pghero_membership_indexes_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      prepare_membership_table
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-016
  it "removes both duplicates while retaining compound indexes and membership rows" do
    original_rows = connection.select_all("SELECT * FROM project_memberships").to_a

    2.times { migration.up }

    expect(indexes).to eq(covering_indexes.transform_values { |columns| columns.map(&:to_s) })
    expect(connection.select_all("SELECT * FROM project_memberships").to_a).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-016
  it "restores each single-column index on rollback without dropping its coverer" do
    migration.up
    2.times { migration.down }

    expect(indexes).to eq(covering_indexes.transform_values { |columns| columns.map(&:to_s) }.merge(
      "index_project_memberships_on_user_id" => [ "user_id" ],
      "index_project_memberships_on_project_id" => [ "project_id" ]))
    expect(connection.select_value("SELECT count(*) FROM project_memberships")).to eq(1)
  end

  # @spec POSTGRESQL-PERSISTENCE-016
  it "retains usable index paths for project and user lookups" do
    migration.up

    { "project_id" => "index_project_memberships_on_project_id_and_role",
      "user_id" => "index_project_memberships_on_user_id_and_project_id" }.each do |column, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM project_memberships WHERE #{column} = 1")
      end
      expect(plan).to include(index)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-016
  it "continues to reject duplicate project memberships after removing the prefix indexes" do
    migration.up

    expect do
      connection.execute("INSERT INTO project_memberships (user_id, project_id, role) VALUES (1, 2, 'viewer')")
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  def indexes
    connection.indexes(:project_memberships).to_h { |index| [ index.name, index.columns ] }
  end

  def prepare_membership_table
    connection.create_table(:project_memberships) do |table|
      table.bigint :user_id
      table.bigint :project_id
      table.string :role
    end
    covering_indexes.each do |name, columns|
      connection.add_index :project_memberships, columns, name: name, unique: columns.first == :user_id
    end
    %i[user_id project_id].each { |column| connection.add_index :project_memberships, column }
    connection.execute("INSERT INTO project_memberships (user_id, project_id, role) VALUES (1, 2, 'viewer')")
  end
end
