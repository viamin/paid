# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-005
RSpec.describe AppleVerificationAttempts::Validate do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:profile) { create(:apple_worker_profile, account: account) }
  let(:workflow) { create(:apple_verification_workflow_revision, project: project, account: account, apple_worker_profile: profile) }
  let(:attempt) do
    create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: profile,
      lifecycle_gate: workflow.lifecycle_gate
    )
  end

  # Eagerly evaluate +attempt+ so tests that mutate the profile or workflow
  # can rely on the attempt being built before their mutation runs.
  before { attempt
FeatureFlags.enable!(:apple_verification_workers, project: project)
   }


  after { FeatureFlags.disable!(:apple_verification_workers, project: project) }

  it "admits a queued attempt when workflow is approved and source is valid" do
    decision = described_class.call(attempt: attempt)

    expect(decision).to be_allowed
    expect(decision.reason).to eq("allowed")
  end

  it "admits a draft workflow during agent iteration advisory gate" do
    workflow.update!(status: "draft")

    decision = described_class.call(attempt: attempt)

    expect(decision).to be_allowed
  end

  it "rejects when the workflow is not approved for a blocking gate" do
    # A draft workflow at a blocking gate cannot bind an attempt via the
    # factory. The model refuses the create because of
    # +workflow_is_eligible_for_gate+. To exercise the service's
    # +workflow_not_approved+ path we stub the workflow resolution to
    # simulate a workflow whose approval was revoked post-hoc.
    draft_workflow = instance_double(
      AppleVerificationWorkflowRevision,
      approved?: false, draft?: true,
      lifecycle_gate: "completion_verification",
      apple_worker_profile: profile
    )
    allow(attempt).to receive(:apple_verification_workflow_revision).and_return(draft_workflow)

    decision = described_class.call(attempt: attempt)

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("workflow_not_approved")
    expect(decision.classification).to eq("project_configuration")
  end

  it "rejects when the bound profile has been revoked" do
    profile.update!(status: "revoked", consecutive_health_failures: 0, quarantined_at: nil)

    decision = described_class.call(attempt: attempt)

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("workflow_profile_revoked")
    expect(decision.classification).to eq("unsupported_capability")
  end

  it "rejects when the worker profile is quarantined" do
    profile.update!(quarantined_at: Time.current, quarantine_reason: "three consecutive health failures", consecutive_health_failures: 3)

    decision = described_class.call(attempt: attempt)

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("worker_quarantined")
    expect(decision.classification).to eq("worker_infrastructure")
  end

  it "rejects when the workflow gate and attempt gate disagree" do
    # The attempt's lifecycle_gate is immutable, so we have to drive a
    # gate mismatch through a stub instead of mutating the attempt
    # directly. The service compares the workflow gate and the attempt
    # gate, so a stubbed mismatch surfaces the same way it would if a
    # future migration dropped the immutability guard.
    approved_workflow = instance_double(
      AppleVerificationWorkflowRevision,
      approved?: true, draft?: false,
      lifecycle_gate: "pull_request_verification",
      apple_worker_profile: profile
    )
    allow(attempt).to receive(:apple_verification_workflow_revision).and_return(approved_workflow)

    decision = described_class.call(attempt: attempt)

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("workflow_gate_mismatch")
  end

  it "rejects with an unsupported-capability classification when the profile declares no capabilities" do
    # Capabilities are immutable after create, so the blank declaration is
    # built into a fresh profile (and a workflow/attempt bound to it)
    # rather than mutated on the shared one.
    bare_profile = create(:apple_worker_profile, account: account, capabilities: {})
    bare_workflow = create(
      :apple_verification_workflow_revision, :approved,
      project: project, account: account, apple_worker_profile: bare_profile
    )
    bare_attempt = create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: bare_workflow,
      apple_worker_profile: bare_profile,
      lifecycle_gate: bare_workflow.lifecycle_gate
    )

    decision = described_class.call(attempt: bare_attempt)

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("capability_unsupported")
    expect(decision.classification).to eq("unsupported_capability")
  end

  it "rejects when the rollout feature flag is disabled for the project" do
    FeatureFlags.disable!(:apple_verification_workers, project: project)

    decision = described_class.call(attempt: attempt)

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("policy_denied")
    expect(decision.classification).to eq("network_policy")
  end

  it "rejects when the account queue depth has hit the configured limit" do
    fill_account_queue_to_limit

    decision = described_class.call(attempt: attempt)

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("quota_exceeded")
    expect(decision.classification).to eq("capacity_or_quota")
  end

  it "rejects when the agent run has already produced too many attempts" do
    bound_attempt = fill_agent_run_attempts_to_limit

    decision = described_class.call(attempt: bound_attempt)

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq("quota_exceeded")
    expect(decision.classification).to eq("capacity_or_quota")
  end

  def fill_account_queue_to_limit
    AppleVerificationAttempts::Queue::DEFAULT_QUEUE_DEPTH.times do
      create(
        :apple_verification_attempt,
        project: project, account: account,
        status: "queued"
      )
    end
  end

  def fill_agent_run_attempts_to_limit
    agent_run = create(:agent_run, project: project)
    bound_workflow = create(
      :apple_verification_workflow_revision, :approved,
      project: project, account: account, apple_worker_profile: profile,
      lifecycle_gate: attempt.lifecycle_gate
    )
    bound_attempt = create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: bound_workflow,
      apple_worker_profile: profile,
      lifecycle_gate: bound_workflow.lifecycle_gate,
      agent_run: agent_run
    )
    AppleVerificationAttempts::Queue::DEFAULT_MAX_ATTEMPTS_PER_RUN.times do
      create(
        :apple_verification_attempt,
        project: project, account: account,
        apple_verification_workflow_revision: bound_workflow,
        apple_worker_profile: profile,
        lifecycle_gate: bound_workflow.lifecycle_gate,
        agent_run: agent_run
      )
    end
    bound_attempt
  end
end
