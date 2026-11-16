# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261116133920_create_stalled_closeout_projection")

RSpec.describe CreateStalledCloseoutProjection, :no_db do # @spec PARTIAL-CLOSEOUT-042
  let(:migration) { described_class.new }

  it "emits tenant-isolation policies for both projection tables" do
    recorded_sql = []

    allow(migration).to receive(:create_table)
    allow(migration).to receive(:add_index)
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up
    joined = recorded_sql.join("\n")

    expect(joined).to include("CREATE POLICY tenant_isolation ON stalled_closeout_projection_checks")
    expect(joined).to include("CREATE POLICY tenant_isolation ON stalled_closeout_projection_rows")
    expect(joined).to include("projects.id = stalled_closeout_projection_checks.project_id")
    expect(joined).to include("projects.id = stalled_closeout_projection_rows.project_id")
    expect(joined).to include("issues.id = stalled_closeout_projection_rows.issue_id")
    expect(joined).to include("projects.account_id = paid_current_account_id()")
  end

  it "drops the projection tenant-isolation policies during rollback" do
    allow(migration).to receive(:drop_table)
    recorded_sql = []
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.down
    joined = recorded_sql.join("\n")

    expect(joined).to include("DROP POLICY IF EXISTS tenant_isolation ON stalled_closeout_projection_checks")
    expect(joined).to include("DROP POLICY IF EXISTS tenant_isolation ON stalled_closeout_projection_rows")
  end
end
