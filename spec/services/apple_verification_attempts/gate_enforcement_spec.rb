# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-011
# @spec APPLE-ATTEMPT-012
# @spec APPLE-ATTEMPT-013
RSpec.describe AppleVerificationAttempts::GateEnforcement do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project) }

  let(:administrator) do
    user = create(:user, account: account)
    user.add_role(:project_admin, project)
    user
  end

  def approved_workflow(lifecycle_gate: "completion_verification")
    revision = create(
      :apple_verification_workflow_revision,
      project: project, account: account,
      lifecycle_gate: lifecycle_gate
    )
    revision.approve!(actor: administrator)
    revision
  end

  def attempt_for(revision, status:, lifecycle_gate: nil)
    create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: revision,
      apple_worker_profile: revision.apple_worker_profile,
      status: status,
      lifecycle_gate: lifecycle_gate || revision.lifecycle_gate,
      agent_run: agent_run
    )
  end

  it "blocks completion when an approved required attempt has not succeeded" do
    revision = approved_workflow
    attempt_for(revision, status: "failed")

    decision = described_class.call(agent_run: agent_run, lifecycle_gate: "completion_verification")

    expect(decision).to be_blocking
    expect(decision.gate).to eq("completion_verification")
  end

  it "does not block when the most-recent attempt for the gate succeeded" do
    revision = approved_workflow
    attempt_for(revision, status: "succeeded")

    decision = described_class.call(agent_run: agent_run, lifecycle_gate: "completion_verification")

    expect(decision).not_to be_blocking
    expect(decision.reason).to eq("satisfied")
  end

  it "does not block when there is no approved workflow" do
    create(
      :apple_verification_workflow_revision,
      project: project, account: account,
      lifecycle_gate: "completion_verification"
    )

    decision = described_class.call(agent_run: agent_run, lifecycle_gate: "completion_verification")

    expect(decision).not_to be_blocking
    expect(decision.reason).to eq("no_approved_workflow")
  end

  it "treats a waiver as releasing the blocking attempt" do
    revision = approved_workflow
    blocking = attempt_for(revision, status: "failed")
    create(
      :apple_verification_waiver,
      account: account, project: project,
      apple_verification_attempt: blocking,
      apple_verification_workflow_revision: revision,
      created_by: administrator,
      source_digest: blocking.source_digest,
      lifecycle_gate: blocking.lifecycle_gate,
      check_ids: revision.required_checks,
      reason: "known simulator outage",
      expires_at: 1.hour.from_now
    )

    decision = described_class.call(agent_run: agent_run, lifecycle_gate: "completion_verification")

    expect(decision).not_to be_blocking
    expect(decision.reason).to eq("waived")
  end

  it "does not block when the workflow has no required checks" do
    revision = create(
      :apple_verification_workflow_revision,
      project: project, account: account,
      apple_worker_profile: create(:apple_worker_profile, account: account),
      lifecycle_gate: "completion_verification",
      required_checks: []
    )
    revision.approve!(actor: administrator)

    decision = described_class.call(agent_run: agent_run, lifecycle_gate: "completion_verification")

    expect(decision).not_to be_blocking
    expect(decision.reason).to eq("no_required_checks")
  end
end
