# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261111113650_create_work_item_project_mappings")

RSpec.describe CreateWorkItemProjectMappings, :no_db do
  # @spec UNIFIED-WORK-ITEMS-004
  it "enables forced tenant RLS for mapping targets through their mapping" do
    migration = described_class.new
    recorded_sql = []
    table = instance_double(ActiveRecord::ConnectionAdapters::TableDefinition,
      references: nil, string: nil, timestamps: nil)

    allow(migration).to receive(:create_table).and_yield(table)
    allow(migration).to receive(:add_index)
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up

    sql = recorded_sql.join("\n")
    expect(sql).to include("ALTER TABLE work_item_project_mapping_targets ENABLE ROW LEVEL SECURITY;")
    expect(sql).to include("ALTER TABLE work_item_project_mapping_targets FORCE ROW LEVEL SECURITY;")
    expect(sql).to include("CREATE POLICY tenant_isolation ON work_item_project_mapping_targets")
    expect(sql).to include("work_item_project_mappings.id = work_item_project_mapping_targets.work_item_project_mapping_id")
    expect(sql.scan("work_item_project_mappings.account_id = paid_current_account_id()").length).to eq(2)
  end

  it "removes the mapping target tenant-isolation policy on rollback" do
    migration = described_class.new
    recorded_sql = []

    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }
    allow(migration).to receive(:drop_table)

    migration.down

    expect(recorded_sql).to include("DROP POLICY IF EXISTS tenant_isolation ON work_item_project_mapping_targets")
    expect(recorded_sql).to include("ALTER TABLE work_item_project_mapping_targets NO FORCE ROW LEVEL SECURITY")
    expect(recorded_sql).to include("ALTER TABLE work_item_project_mapping_targets DISABLE ROW LEVEL SECURITY")
  end
end
