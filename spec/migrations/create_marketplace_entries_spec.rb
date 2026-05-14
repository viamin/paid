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

  it "enables tenant row-level security on marketplace tables" do
    migration.up

    %w[
      marketplace_entries
      marketplace_entry_versions
      marketplace_entry_rules
      agent_run_marketplace_entries
    ].each do |table_name|
      expect(tenant_policy_present?(table_name)).to be(true)
      expect(row_level_security_enabled?(table_name)).to be(true)
      expect(row_level_security_forced?(table_name)).to be(true)
    end

    expect(policy_for("marketplace_entry_versions").fetch("qual")).to include("marketplace_entries.account_id = paid_current_account_id()")
    expect(policy_for("marketplace_entry_rules").fetch("qual")).to include("marketplace_entries.account_id = paid_current_account_id()")
    expect(policy_for("agent_run_marketplace_entries").fetch("qual")).to include("agent_runs.account_id = paid_current_account_id()")
  end

  private

  def teardown_schema
    migration.down if connection.table_exists?(:agent_run_marketplace_entries) ||
      connection.table_exists?(:marketplace_entry_rules) ||
      connection.table_exists?(:marketplace_entry_versions) ||
      connection.table_exists?(:marketplace_entries)
  end

  def tenant_policy_present?(table_name)
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = '#{table_name}'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def row_level_security_enabled?(table_name)
    truthy?(connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'public.#{table_name}'::regclass"))
  end

  def row_level_security_forced?(table_name)
    truthy?(connection.select_value("SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.#{table_name}'::regclass"))
  end

  def policy_for(table_name)
    connection.select_one(<<~SQL.squish)
      SELECT qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = '#{table_name}'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
