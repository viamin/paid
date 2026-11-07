# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261107120000_create_post_deploy_measurements")

# @spec POST-DEPLOY-004
RSpec.describe CreatePostDeployMeasurements, :no_db do
  let(:migration) { described_class.new }

  before do
    allow(migration).to receive_messages(create_table: nil, add_index: nil,
      add_check_constraint: nil, execute: nil)
  end

  it "enables and forces row-level security with a tenant policy" do
    migration.up

    expect(migration).to have_received(:execute)
      .with("ALTER TABLE post_deploy_measurements ENABLE ROW LEVEL SECURITY")
    expect(migration).to have_received(:execute)
      .with("ALTER TABLE post_deploy_measurements FORCE ROW LEVEL SECURITY")
    expect(migration).to have_received(:execute)
      .with("DROP POLICY IF EXISTS tenant_isolation ON post_deploy_measurements")
    expect(migration).to have_received(:execute).with(start_with("CREATE POLICY tenant_isolation ON post_deploy_measurements"))
  end

  it "binds the tenant policy to the current account and its project/issue rows" do
    policy_sql = nil
    allow(migration).to receive(:execute) { |sql| policy_sql = sql if sql.to_s.start_with?("CREATE POLICY") }

    migration.up

    expect(policy_sql).to include("post_deploy_measurements.account_id = paid_current_account_id()")
    expect(policy_sql).to include("USING (paid_tenant_bypass() OR")
    expect(policy_sql).to include("WITH CHECK (paid_tenant_bypass() OR")
  end

  it "creates the idempotency unique index over issue, check, version, and revision" do
    migration.up

    expect(migration).to have_received(:add_index).with(
      :post_deploy_measurements,
      [ :issue_id, :check_key, :check_version, :deployed_revision ],
      unique: true, name: "index_post_deploy_measurements_on_idempotency_key"
    )
  end

  it "reverses cleanly" do
    allow(migration).to receive(:drop_table)

    migration.down

    expect(migration).to have_received(:execute)
      .with("DROP POLICY IF EXISTS tenant_isolation ON post_deploy_measurements")
    expect(migration).to have_received(:drop_table).with(:post_deploy_measurements)
  end
end
