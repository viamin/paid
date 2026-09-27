# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260926055834_create_apple_verification_worker_healths")

RSpec.describe CreateAppleVerificationWorkerHealths, :no_db do
  # @spec APPLE-ATTEMPT-015
  let(:migration) { described_class.new }

  before do
    allow(migration).to receive_messages(
      table_exists?: true,
      check_constraint_exists?: false
    )
    allow(migration).to receive(:add_check_constraint)
    allow(migration).to receive(:safety_assured).and_yield
  end

  it "forces worker-health rows through the owning profile tenant policy" do
    recorded_sql = []
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up

    sql = recorded_sql.join("\n")
    expect(sql).to include("ALTER TABLE apple_verification_worker_healths ENABLE ROW LEVEL SECURITY")
    expect(sql).to include("ALTER TABLE apple_verification_worker_healths FORCE ROW LEVEL SECURITY")
    expect(sql).to include("CREATE POLICY tenant_isolation ON apple_verification_worker_healths")
    expect(sql).to include("apple_worker_profiles.id = apple_verification_worker_healths.apple_worker_profile_id")
    expect(sql).to include("apple_worker_profiles.account_id = paid_current_account_id()")
  end
end
