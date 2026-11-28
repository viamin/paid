# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128045053_remove_redundant_runner_auth_attempt_indexes")

RSpec.describe RemoveRedundantRunnerAuthAttemptIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:covering_indexes) do
    {
      "idx_runner_auth_attempts_account_attempted" => [ :account_id, :attempted_at ],
      "idx_runner_auth_attempts_run_stage_attempted" => [ :agent_run_id, :attempt_stage, :attempted_at ],
      "idx_runner_auth_attempts_project_attempted" => [ :project_id, :attempted_at ]
    }
  end

  around do |example|
    schema = "pghero_auth_indexes_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      prepare_attempt_table
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-015
  it "removes all three duplicates while retaining compound indexes and telemetry rows" do
    original_rows = connection.select_all("SELECT * FROM runner_auth_attempts").to_a

    2.times { migration.up }

    expect(indexes).to eq(covering_indexes.transform_values { |columns| columns.map(&:to_s) })
    expect(connection.select_all("SELECT * FROM runner_auth_attempts").to_a).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-015
  it "restores each single-column index on rollback without dropping its coverer" do
    migration.up
    2.times { migration.down }

    expect(indexes).to eq(covering_indexes.transform_values { |columns| columns.map(&:to_s) }.merge(
      "index_runner_auth_attempts_on_account_id" => [ "account_id" ],
      "index_runner_auth_attempts_on_agent_run_id" => [ "agent_run_id" ],
      "index_runner_auth_attempts_on_project_id" => [ "project_id" ]))
    expect(connection.select_value("SELECT count(*) FROM runner_auth_attempts")).to eq(1)
  end

  # @spec POSTGRESQL-PERSISTENCE-015
  it "retains usable index paths for account, run and project lookups" do
    migration.up

    { "account_id" => "idx_runner_auth_attempts_account_attempted",
      "agent_run_id" => "idx_runner_auth_attempts_run_stage_attempted",
      "project_id" => "idx_runner_auth_attempts_project_attempted" }.each do |column, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM runner_auth_attempts WHERE #{column} = 1")
      end
      expect(plan).to include(index)
    end
  end

  def indexes
    connection.indexes(:runner_auth_attempts).to_h { |index| [ index.name, index.columns ] }
  end

  def prepare_attempt_table
    connection.create_table(:runner_auth_attempts) do |table|
      table.bigint :account_id
      table.bigint :agent_run_id
      table.bigint :project_id
      table.string :attempt_stage
      table.timestamp :attempted_at
    end
    covering_indexes.each { |name, columns| connection.add_index :runner_auth_attempts, columns, name: name }
    %i[account_id agent_run_id project_id].each { |column| connection.add_index :runner_auth_attempts, column }
    connection.execute("INSERT INTO runner_auth_attempts (account_id, agent_run_id, project_id, attempt_stage, attempted_at) VALUES (1, 2, 3, 'refresh', '2026-11-28 00:00:00')")
  end
end
