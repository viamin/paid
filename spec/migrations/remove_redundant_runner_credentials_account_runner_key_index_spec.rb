# frozen_string_literal: true

require "rails_helper"
require Rails.root.glob("db/migrate/*_remove_redundant_runner_credentials_account_runner_key_index.rb").sole

RSpec.describe RemoveRedundantRunnerCredentialsAccountRunnerKeyIndex do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    schema = "pghero_credentials_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      connection.create_table(:runner_credentials) do |t|
        t.bigint :account_id
        t.string :runner_key
        t.string :name
        t.datetime :revoked_at
      end
      connection.add_index :runner_credentials, :account_id
      connection.add_index :runner_credentials, %i[account_id runner_key]
      connection.add_index :runner_credentials, %i[account_id revoked_at]
      connection.add_index :runner_credentials, %i[account_id runner_key name], unique: true,
        name: "idx_runner_credentials_on_account_runner_key_name"
      connection.execute("INSERT INTO runner_credentials (account_id, runner_key, name) VALUES (1, 'test', 'primary')")
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-041
  it "removes both redundant prefixes while preserving records and retained indexes" do
    original = indexes
    rows = connection.select_all("SELECT * FROM runner_credentials").to_a
    migration.up

    expect(indexes).to eq(original.except(
      "index_runner_credentials_on_account_id",
      "index_runner_credentials_on_account_id_and_runner_key"
    ))
    expect(connection.select_all("SELECT * FROM runner_credentials").to_a).to eq(rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-041
  it "restores both original definitions and permits reapplication" do
    original = indexes
    migration.up
    migration.down
    expect(indexes).to eq(original)
    migration.up
    expect(indexes.keys).not_to include("index_runner_credentials_on_account_id", "index_runner_credentials_on_account_id_and_runner_key")
  end

  # @spec POSTGRESQL-PERSISTENCE-041
  it "preserves credential identity uniqueness while permitting distinct accounts and names" do
    migration.up
    statement = "INSERT INTO runner_credentials (account_id, runner_key, name) VALUES (1, 'test', 'primary')"
    expect { connection.execute(statement) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { connection.execute(statement.sub("'primary'", "'secondary'")) }.not_to raise_error
    expect { connection.execute(statement.sub("VALUES (1,", "VALUES (2,")) }.not_to raise_error
  end

  def indexes
    connection.indexes(:runner_credentials).to_h do |index|
      [ index.name, [ index.columns, index.unique, index.where, index.valid? ] ]
    end
  end
end
