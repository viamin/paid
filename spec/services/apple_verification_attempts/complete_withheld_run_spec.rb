# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::CompleteWithheldRun do
  # @spec APPLE-ATTEMPT-011
  # @spec APPLE-ATTEMPT-013
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, apple_verification_mode: "on_demand") }
  let(:agent_run) { create(:agent_run, :running, project:) }

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
  end

  def approved_required_revision
    create(
      :apple_verification_workflow_revision,
      :approved,
      project:,
      lifecycle_gate: "completion_verification",
      required_checks: %w[ios-app.tests],
      advisory_checks: []
    )
  end

  def attempt_for(revision, status:, failure_classification: nil, retry_number: 0)
    create(
      :apple_verification_attempt,
      project:,
      agent_run:,
      apple_verification_workflow_revision: revision,
      apple_worker_profile: revision.apple_worker_profile,
      lifecycle_gate: revision.lifecycle_gate,
      status:,
      failure_classification:,
      retry_number:
    )
  end

  def withhold_completion
    revision = approved_required_revision
    result = agent_run.complete!(
      result_commit: "a" * 40,
      pr_url: "https://github.com/example/pull/7",
      pr_number: 7
    )
    expect(result).to be_falsey
    revision
  end

  it "completes the withheld run with the preserved completion payload once the gate is satisfied" do
    revision = withhold_completion
    attempt_for(revision, status: "succeeded")

    expect(described_class.call(agent_run:)).to be_truthy

    agent_run.reload
    expect(agent_run.status).to eq("completed")
    expect(agent_run.result_commit_sha).to eq("a" * 40)
    expect(agent_run.pull_request_url).to eq("https://github.com/example/pull/7")
    expect(agent_run.pull_request_number).to eq(7)
    expect(agent_run.external_metadata).not_to have_key(AgentRun::COMPLETION_VERIFICATION_WITHHELD_METADATA_KEY)
  end

  it "keeps the run withheld while verification is still pending" do
    revision = withhold_completion
    attempt_for(revision, status: "failed", failure_classification: "worker_infrastructure")

    expect(described_class.call(agent_run:)).to be_falsey
    expect(agent_run.reload.status).to eq("running")
    expect(AgentRun.awaiting_completion_verification).to contain_exactly(agent_run)
  end

  it "keeps the run withheld while the gate is blocked without a waiver" do
    revision = withhold_completion
    attempt_for(revision, status: "failed", failure_classification: "test_assertion")

    expect(described_class.call(agent_run:)).to be_falsey
    expect(agent_run.reload.status).to eq("running")
  end

  it "is a no-op for a run without a withheld completion" do
    revision = approved_required_revision
    attempt_for(revision, status: "succeeded")

    expect(described_class.call(agent_run:)).to be_falsey
    expect(agent_run.reload.status).to eq("running")
  end

  it "is a no-op once the run is finished" do
    revision = withhold_completion
    attempt_for(revision, status: "succeeded")
    agent_run.complete!

    expect(described_class.call(agent_run:)).to be_falsey
    expect(agent_run.reload.status).to eq("completed")
  end
end
