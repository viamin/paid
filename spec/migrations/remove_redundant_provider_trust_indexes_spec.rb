# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128082532_remove_redundant_provider_trust_indexes")

RSpec.describe RemoveRedundantProviderTrustIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:tables) { %i[provider_identity_mappings trusted_provider_identities] }
  let(:removed_names) { tables.map { |table| "index_#{table}_on_account_id" } }

  around do |example|
    schema = "pghero_provider_trust_#{SecureRandom.hex(6)}"
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

  # @spec POSTGRESQL-PERSISTENCE-026
  it "removes only the two redundant prefixes while preserving rows and other indexes" do
    original_indexes = indexes
    original_rows = rows
    2.times { migration.up }

    expect(indexes).to eq(original_indexes.transform_values { |definitions| definitions.except(*removed_names) })
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-026
  it "restores exact original definitions on repeated rollback" do
    original_indexes = indexes
    original_rows = rows
    migration.up
    2.times { migration.down }

    expect(indexes).to eq(original_indexes)
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-026
  it "preserves both provider mapping identities and cross-account independence" do
    migration.up
    duplicates = [
      "INSERT INTO provider_identity_mappings (account_id, user_id, provider, external_id) VALUES (1, 1, 'linear', 'other')",
      "INSERT INTO provider_identity_mappings (account_id, user_id, provider, external_id) VALUES (1, 2, 'linear', 'external')"
    ]
    duplicates.each { |sql| expect { connection.execute(sql) }.to raise_error(ActiveRecord::RecordNotUnique) }
    expect do
      connection.execute("INSERT INTO provider_identity_mappings (account_id, user_id, provider, external_id) VALUES (2, 1, 'linear', 'external')")
    end.not_to raise_error
  end

  # @spec POSTGRESQL-PERSISTENCE-026
  it "preserves account defaults and project-specific trust uniqueness" do
    migration.up
    duplicate = "INSERT INTO trusted_provider_identities (account_id, project_id, provider, identity_type, external_id) VALUES (1, NULL, 'linear', 'user', 'trusted')"
    expect { connection.execute(duplicate) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { connection.execute(duplicate.sub("1, NULL", "1, 7")) }.not_to raise_error
    expect { connection.execute(duplicate.sub("1, NULL", "1, 7")) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { connection.execute(duplicate.sub("1, NULL", "2, NULL")) }.not_to raise_error
  end

  # @spec POSTGRESQL-PERSISTENCE-026
  it "retains usable provider identity and trusted-scope lookup paths" do
    migration.up
    queries = {
      "provider_identity_mappings WHERE account_id = 1 AND provider = 'linear' AND external_id = 'external'" => "index_provider_identity_mappings_on_provider_identity",
      "provider_identity_mappings WHERE account_id = 1 AND user_id = 1 AND provider = 'linear'" => %w[index_provider_identity_mappings_on_user_and_provider index_provider_identity_mappings_on_provider_identity],
      "trusted_provider_identities WHERE account_id = 1 AND project_id = 7 AND provider = 'linear' AND identity_type = 'user' AND external_id = 'trusted'" => "index_trusted_identities_on_scope"
    }
    queries.each do |query, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM #{query}")
      end
      expect(plan).to match(Regexp.union(Array(index)))
    end
  end

  def indexes
    tables.to_h do |table|
      [ table, connection.indexes(table).to_h { |index| [ index.name, [ index.columns, index.unique, index.where ] ] } ]
    end
  end

  def rows
    tables.to_h { |table| [ table, connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ] }
  end

  def prepare_tables
    connection.create_table(:provider_identity_mappings) do |t|
      %i[account_id user_id created_by_id].each { |column| t.bigint column }
      %i[provider external_id].each { |column| t.string column }
    end
    connection.create_table(:trusted_provider_identities) do |t|
      %i[account_id project_id created_by_id].each { |column| t.bigint column }
      %i[provider identity_type external_id].each { |column| t.string column }
    end
    tables.each do |table|
      connection.add_index table, :account_id
      connection.add_index table, :created_by_id
    end
    connection.add_index :provider_identity_mappings, :user_id
    connection.add_index :provider_identity_mappings, %i[account_id user_id provider], unique: true, name: "index_provider_identity_mappings_on_user_and_provider"
    connection.add_index :provider_identity_mappings, %i[account_id provider external_id], unique: true, name: "index_provider_identity_mappings_on_provider_identity"
    connection.add_index :trusted_provider_identities, :project_id
    connection.add_index :trusted_provider_identities, %i[account_id project_id provider identity_type external_id], unique: true, name: "index_trusted_identities_on_scope"
    connection.add_index :trusted_provider_identities, %i[account_id provider identity_type external_id], unique: true, where: "project_id IS NULL", name: "index_trusted_identities_on_account_default"
    connection.execute("INSERT INTO provider_identity_mappings (account_id, user_id, provider, external_id) VALUES (1, 1, 'linear', 'external')")
    connection.execute("INSERT INTO trusted_provider_identities (account_id, provider, identity_type, external_id) VALUES (1, 'linear', 'user', 'trusted')")
  end
end
