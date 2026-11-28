# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128095755_remove_redundant_provider_api_keys_user_id_index")

RSpec.describe RemoveRedundantProviderApiKeysUserIdIndex do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    schema = "pghero_provider_keys_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      prepare_table
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-030
  it "removes only the redundant user prefix while preserving credential records" do
    original_indexes = indexes
    original_rows = rows
    migration.up

    expect(indexes).to eq(original_indexes.except("index_provider_api_keys_on_user_id"))
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-030
  it "restores the exact original index on rollback and permits reapplication" do
    original_indexes = indexes
    original_rows = rows
    migration.up
    migration.down

    expect(indexes).to eq(original_indexes)
    expect(rows).to eq(original_rows)
    expect { migration.up }.not_to raise_error
  end

  # @spec POSTGRESQL-PERSISTENCE-030
  it "retains unique names per user without preventing other users or names" do
    migration.up
    statement = "INSERT INTO provider_api_keys (user_id, name) VALUES (1, 'primary')"

    expect { connection.execute(statement) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { connection.execute(statement.sub("'primary'", "'secondary'")) }.not_to raise_error
    expect { connection.execute(statement.sub("VALUES (1,", "VALUES (2,")) }.not_to raise_error
  end

  # @spec POSTGRESQL-PERSISTENCE-030
  it "retains ordered user-prefix and full identity lookup paths" do
    migration.up
    [ "WHERE user_id = 1 ORDER BY name", "WHERE user_id = 1 AND name = 'primary'" ].each do |predicate|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM provider_api_keys #{predicate}")
      end
      expect(plan).to include("index_provider_api_keys_on_user_id_and_name")
    end
  end

  def indexes
    connection.indexes(:provider_api_keys).to_h do |index|
      [ index.name, [ index.columns, index.unique, index.where, index.orders, index.valid? ] ]
    end
  end

  def rows
    connection.select_all("SELECT * FROM provider_api_keys ORDER BY id").to_a
  end

  def prepare_table
    connection.create_table(:provider_api_keys) do |t|
      t.bigint :user_id
      %i[name api_service_type api_key].each { |column| t.string column }
    end
    connection.add_index :provider_api_keys, :user_id
    connection.add_index :provider_api_keys, %i[user_id api_service_type]
    connection.add_index :provider_api_keys, %i[user_id name], unique: true
    connection.execute("INSERT INTO provider_api_keys (user_id, name, api_service_type, api_key) VALUES (1, 'primary', 'test', 'fixture-credential')")
  end
end
