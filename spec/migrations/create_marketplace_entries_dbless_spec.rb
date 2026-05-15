# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260514223539_create_marketplace_entries")

RSpec.describe CreateMarketplaceEntries, :no_db do
  let(:migration) { described_class.new }

  it "emits tenant-isolation policies for all marketplace tables" do
    recorded_sql = []

    allow(migration).to receive(:create_table)
    allow(migration).to receive(:add_reference)
    allow(migration).to receive(:add_index)
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up

    expect(recorded_sql.join("\n")).to include("CREATE POLICY tenant_isolation ON marketplace_entries")
    expect(recorded_sql.join("\n")).to include("CREATE POLICY tenant_isolation ON marketplace_entry_versions")
    expect(recorded_sql.join("\n")).to include("marketplace_entries.account_id = paid_current_account_id()")
    expect(recorded_sql.join("\n")).to include("CREATE POLICY tenant_isolation ON marketplace_entry_rules")
    expect(recorded_sql.join("\n")).to include("CREATE POLICY tenant_isolation ON agent_run_marketplace_entries")
    expect(recorded_sql.join("\n")).to include("INNER JOIN projects ON projects.id = agent_runs.project_id")
    expect(recorded_sql.join("\n")).to include("projects.account_id = paid_current_account_id()")
  end

  it "drops marketplace tenant-isolation policies during rollback" do
    allow(migration).to receive(:table_exists?).and_return(true)
    allow(migration).to receive(:column_exists?).with(:marketplace_entries, :current_version_id).and_return(true)
    allow(migration).to receive(:remove_foreign_key)
    allow(migration).to receive(:remove_reference)
    allow(migration).to receive(:drop_table)

    recorded_sql = []
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.down

    expect(recorded_sql.join("\n")).to include("DROP POLICY IF EXISTS tenant_isolation ON marketplace_entries")
    expect(recorded_sql.join("\n")).to include("DROP POLICY IF EXISTS tenant_isolation ON marketplace_entry_versions")
    expect(recorded_sql.join("\n")).to include("DROP POLICY IF EXISTS tenant_isolation ON marketplace_entry_rules")
    expect(recorded_sql.join("\n")).to include("DROP POLICY IF EXISTS tenant_isolation ON agent_run_marketplace_entries")
  end
end
