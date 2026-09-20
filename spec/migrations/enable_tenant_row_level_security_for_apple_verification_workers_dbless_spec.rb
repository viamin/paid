# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260919105106_enable_tenant_row_level_security_for_apple_verification_workers")

RSpec.describe EnableTenantRowLevelSecurityForAppleVerificationWorkers, :no_db do
  let(:migration) { described_class.new }

  before do
    allow(migration).to receive(:safety_assured).and_yield
    allow(migration).to receive(:table_exists?).and_return(true)
    allow(migration).to receive(:quote_table_name) { |table| table }
  end

  it "forces account, project, and reference-aware tenant policies" do # @spec APPLE-WORKER-005 @spec APPLE-WORKER-006
    recorded_sql = []
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up

    sql = recorded_sql.join("\n")
    expect(sql).to include("ALTER TABLE apple_worker_profiles FORCE ROW LEVEL SECURITY")
    expect(sql).to include("ALTER TABLE apple_verification_workflow_revisions FORCE ROW LEVEL SECURITY")
    expect(sql).to include("ALTER TABLE apple_verification_attempts FORCE ROW LEVEL SECURITY")
    expect(sql).to include("ALTER TABLE apple_verification_waivers FORCE ROW LEVEL SECURITY")
    expect(sql).to include("projects.account_id = paid_current_account_id()")
    expect(sql).to include("apple_verification_workflow_revisions.apple_worker_profile_id = apple_verification_attempts.apple_worker_profile_id")
    expect(sql).to include("apple_verification_attempts.apple_verification_workflow_revision_id = apple_verification_waivers.apple_verification_workflow_revision_id")
  end
end
