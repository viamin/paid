# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260514223539_create_marketplace_entries")

RSpec.describe CreateMarketplaceEntries, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    tables = %i[
      agent_run_marketplace_entries
      marketplace_entry_rules
      marketplace_entry_versions
      marketplace_entries
    ]
    preexisting = tables.index_with { |table| connection.table_exists?(table) }

    teardown_schema
    example.run
  ensure
    teardown_schema
    migration.up if preexisting.values.any?
  end

  it "creates marketplace tables and the current_version reference" do
    migration.up

    expect(connection.table_exists?(:marketplace_entries)).to be(true)
    expect(connection.table_exists?(:marketplace_entry_versions)).to be(true)
    expect(connection.table_exists?(:marketplace_entry_rules)).to be(true)
    expect(connection.table_exists?(:agent_run_marketplace_entries)).to be(true)

    expect(connection.column_exists?(:marketplace_entries, :current_version_id)).to be(true)
    expect(connection.foreign_key_exists?(:marketplace_entries, :marketplace_entry_versions, column: :current_version_id)).to be(true)
    expect(connection.index_exists?(:marketplace_entries, [ :account_id, :entry_type, :status ])).to be(true)
    expect(connection.index_exists?(:agent_run_marketplace_entries, [ :agent_run_id, :marketplace_entry_id ], unique: true)).to be(true)
  end

  private

  def teardown_schema
    migration.down if connection.table_exists?(:agent_run_marketplace_entries) ||
      connection.table_exists?(:marketplace_entry_rules) ||
      connection.table_exists?(:marketplace_entry_versions) ||
      connection.table_exists?(:marketplace_entries)
  end
end
