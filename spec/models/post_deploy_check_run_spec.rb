# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-CHECK-001
RSpec.describe PostDeployCheckRun do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  def build_run(**attrs)
    described_class.new(
      account:, project:, check_key: "closed_agent_planning_hold_reconciliation_count", check_version: 1,
      deployed_revision: "abc123", idempotency_key: "key-#{SecureRandom.hex(4)}", status: "pending", **attrs
    )
  end

  it "requires status to be one of the known lifecycle values" do
    run = build_run(status: "bogus")

    expect(run).not_to be_valid
    expect(run.errors[:status]).to be_present
  end

  it "enforces idempotency_key uniqueness within an account" do
    build_run(idempotency_key: "shared-key").save!

    duplicate = build_run(idempotency_key: "shared-key")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:idempotency_key]).to be_present
  end

  it "rejects a project belonging to a different account" do
    other_project = create(:project)
    run = build_run(project: other_project)

    expect(run).not_to be_valid
    expect(run.errors[:project]).to be_present
  end

  it "scopes .current to rows that have not been superseded" do
    superseded = build_run(idempotency_key: "old").tap(&:save!)
    current = build_run(idempotency_key: "new").tap(&:save!)
    superseded.update!(superseded_by: current)

    expect(described_class.current).to contain_exactly(current)
  end
end
