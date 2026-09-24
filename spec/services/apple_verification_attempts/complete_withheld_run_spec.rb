# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::CompleteWithheldRun do
  # @spec APPLE-ATTEMPT-011
  # @spec APPLE-ATTEMPT-013
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, apple_verification_mode: "on_demand") }
  let(:agent_run) { create(:agent_run, :running, project:) }
  # The shipped commit. The factory leaves `commit_sha` nil by default because
  # bundle-based attempts on draft revisions carry no SHA, but the
  # completion-verification gate only sees attempts on approved revisions and
  # binds them to the commit being shipped, so tests should set it explicitly.
  let(:shipped_commit) { "a" * 40 }

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

  def attempt_for(revision, status:, failure_classification: nil, retry_number: 0, commit_sha: nil)
    create(
      :apple_verification_attempt,
      project:,
      agent_run:,
      apple_verification_workflow_revision: revision,
      apple_worker_profile: revision.apple_worker_profile,
      lifecycle_gate: revision.lifecycle_gate,
      status:,
      failure_classification:,
      retry_number:,
      commit_sha:
    )
  end

  def withhold_completion
    revision = approved_required_revision
    result = agent_run.complete!(
      result_commit: shipped_commit,
      pr_url: "https://github.com/example/pull/7",
      pr_number: 7
    )
    expect(result).to be_falsey
    revision
  end

  it "completes the withheld run with the preserved completion payload once the gate is satisfied" do
    revision = withhold_completion
    attempt_for(revision, status: "succeeded", commit_sha: shipped_commit)

    expect(described_class.call(agent_run:)).to be_truthy

    agent_run.reload
    expect(agent_run.status).to eq("completed")
    expect(agent_run.result_commit_sha).to eq(shipped_commit)
    expect(agent_run.pull_request_url).to eq("https://github.com/example/pull/7")
    expect(agent_run.pull_request_number).to eq(7)
    expect(agent_run.external_metadata).not_to have_key(AgentRun::COMPLETION_VERIFICATION_WITHHELD_METADATA_KEY)
  end

  it "completes the withheld run when its matching attempt records success" do
    revision = withhold_completion
    attempt = attempt_for(revision, status: "running", commit_sha: shipped_commit)

    attempt.update!(status: "succeeded", finished_at: Time.current)

    expect(agent_run.reload).to have_attributes(status: "completed", result_commit_sha: shipped_commit)
  end

  it "keeps the run withheld while verification is still pending" do
    revision = withhold_completion
    attempt_for(revision, status: "failed", failure_classification: "worker_infrastructure", commit_sha: shipped_commit)

    expect(described_class.call(agent_run:)).to be_falsey
    expect(agent_run.reload.status).to eq("running")
    expect(AgentRun.awaiting_completion_verification).to contain_exactly(agent_run)
  end

  it "keeps the run withheld while the gate is blocked without a waiver" do
    revision = withhold_completion
    attempt_for(revision, status: "failed", failure_classification: "test_assertion", commit_sha: shipped_commit)

    expect(described_class.call(agent_run:)).to be_falsey
    expect(agent_run.reload.status).to eq("running")
  end

  it "is a no-op for a run without a withheld completion" do
    revision = approved_required_revision
    attempt_for(revision, status: "succeeded", commit_sha: shipped_commit)

    expect(described_class.call(agent_run:)).to be_falsey
    expect(agent_run.reload.status).to eq("running")
  end

  it "is a no-op once the run is finished" do
    revision = withhold_completion
    attempt_for(revision, status: "succeeded", commit_sha: shipped_commit)
    # Drive completion via the public `complete!` with the matched commit so
    # the gate is satisfied and the run is no longer parked.
    expect(agent_run.complete!(result_commit: shipped_commit)).to be_truthy

    expect(described_class.call(agent_run:)).to be_falsey
    expect(agent_run.reload.status).to eq("completed")
  end

  it "keeps the run withheld when an attempted commit does not match the shipped commit" do
    revision = withhold_completion
    attempt_for(revision, status: "succeeded", commit_sha: "b" * 40)

    expect(described_class.call(agent_run:)).to be_falsey
    agent_run.reload
    expect(agent_run.status).to eq("running")
    expect(AgentRun.awaiting_completion_verification).to contain_exactly(agent_run)
  end
end
