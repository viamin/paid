# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128100626_remove_redundant_run_resource_indexes")

RSpec.describe RemoveRedundantRunResourceIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:tables) { %i[provisioning_intents runner_auth_materializations] }

  around do |example|
    schema = "pghero_run_resources_#{SecureRandom.hex(6)}"
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

  # @spec POSTGRESQL-PERSISTENCE-029
  it "removes only two redundant prefixes without changing ledger records" do
    original_indexes = indexes
    original_rows = rows
    2.times { migration.up }

    tables.each do |table|
      expect(indexes.fetch(table)).to eq(original_indexes.fetch(table).except("index_#{table}_on_agent_run_id"))
    end
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-029
  it "restores exact definitions on repeated rollback without changing provenance" do
    original_indexes = indexes
    original_rows = rows
    migration.up
    2.times { migration.down }

    expect(indexes).to eq(original_indexes)
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-029
  it "retains provisioning retry identity and credential container uniqueness" do
    migration.up
    statements = [
      "INSERT INTO provisioning_intents (agent_run_id, resource_kind, attempt) VALUES (1, 'container', 0)",
      "INSERT INTO runner_auth_materializations (agent_run_id, runner_key, container_id) VALUES (1, 'codex', 'container-1')"
    ]
    statements.each do |statement|
      expect { connection.execute(statement) }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { connection.execute(statement.sub("VALUES (1,", "VALUES (2,")) }.not_to raise_error
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-029
  it "retains full run-prefix and identity lookup paths including intents without request IDs" do
    migration.up
    queries = {
      provisioning_intents: "agent_run_id = 1 AND resource_kind = 'container' AND attempt = 0",
      runner_auth_materializations: "agent_run_id = 1 AND runner_key = 'codex' AND container_id = 'container-1'"
    }
    queries.each do |table, predicate|
      [ "agent_run_id = 1", predicate ].each do |where|
        plan = connection.transaction do
          connection.execute("SET LOCAL enable_seqscan = off")
          connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM #{table} WHERE #{where}")
        end
        expect(plan).to include(table == :provisioning_intents ? "index_provisioning_intents_on_run_kind_attempt" : "idx_runner_auth_materializations_run_runner_container")
      end
    end
    expect(connection.select_value("SELECT request_id FROM provisioning_intents WHERE agent_run_id = 1")).to be_nil
  end

  def indexes
    tables.to_h do |table|
      [ table, connection.indexes(table).to_h { |index| [ index.name, [ index.columns, index.unique, index.where, index.orders, index.valid? ] ] } ]
    end
  end

  def rows
    tables.to_h { |table| [ table, connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ] }
  end

  def prepare_tables
    tables.each do |table|
      connection.create_table(table) do |t|
        %i[account_id agent_run_id project_id].each { |column| t.bigint column }
        t.jsonb :metadata, default: {}
      end
      %i[account_id agent_run_id project_id].each { |column| connection.add_index table, column }
    end
    prepare_intents
    prepare_materializations
  end

  def prepare_intents
    connection.change_table(:provisioning_intents) do |t|
      %i[resource_kind runner_type request_id provider_resource_id status].each { |column| t.string column }
      t.integer :attempt
      t.timestamp :created_at
    end
    connection.add_index :provisioning_intents, %i[agent_run_id resource_kind attempt], unique: true, name: "index_provisioning_intents_on_run_kind_attempt"
    connection.add_index :provisioning_intents, %i[agent_run_id runner_type request_id], unique: true,
      name: "index_provisioning_intents_on_run_runner_request", where: "request_id IS NOT NULL"
    connection.add_index :provisioning_intents, :provider_resource_id, where: "provider_resource_id IS NOT NULL"
    connection.add_index :provisioning_intents, %i[status created_at]
    connection.execute("INSERT INTO provisioning_intents (agent_run_id, resource_kind, attempt, metadata) VALUES (1, 'container', 0, '{\"state\":\"pending\"}')")
  end

  def prepare_materializations
    connection.change_table(:runner_auth_materializations) do |t|
      t.bigint :runner_credential_id
      %i[runner_key container_id].each { |column| t.string column }
      t.timestamp :credential_updated_at
    end
    connection.add_index :runner_auth_materializations, :runner_credential_id
    connection.add_index :runner_auth_materializations, %i[agent_run_id runner_key container_id], unique: true, name: "idx_runner_auth_materializations_run_runner_container"
    connection.execute("INSERT INTO runner_auth_materializations (agent_run_id, runner_key, container_id, metadata, credential_updated_at) VALUES (1, 'codex', 'container-1', '{\"generation\":\"original\"}', '2026-11-27')")
  end
end
