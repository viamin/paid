# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Waive do
  # @spec APPLE-VERIFY-006
  # @spec APPLE-ATTEMPT-013
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, apple_verification_mode: "on_demand") }
  let(:agent_run) { create(:agent_run, :running, project:) }
  let(:shipped_commit) { "0123456789abcdef0123456789abcdef01234567" }
  let!(:revision) do
    create(
      :apple_verification_workflow_revision,
      :approved,
      project:,
      lifecycle_gate: "completion_verification",
      required_checks: %w[ios-app.tests],
      advisory_checks: []
    )
  end
  let!(:attempt) do
    create(
      :apple_verification_attempt,
      project:,
      agent_run:,
      apple_verification_workflow_revision: revision,
      apple_worker_profile: revision.apple_worker_profile,
      lifecycle_gate: revision.lifecycle_gate,
      status: "failed",
      failure_classification: "worker_infrastructure",
      commit_sha: shipped_commit
    )
  end
  let(:actor) do
    create(:user, account:).tap { |user| user.add_role(:project_admin, project) }
  end

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
  end

  def waive
    described_class.call(
      attempt:,
      actor:,
      attributes: { reason: "Known simulator outage", expires_at: 1.hour.from_now, check_ids: revision.required_checks }
    )
  end

  it "creates the one-attempt waiver" do
    waiver = waive

    expect(waiver).to be_persisted
    expect(waiver).to be_active
    expect(attempt.apple_verification_waivers).to contain_exactly(waiver)
  end

  it "completes an agent run whose completion was withheld on the waived attempt" do
    expect(
      agent_run.complete!(result_commit: shipped_commit, pr_url: "https://github.com/example/pull/7", pr_number: 7)
    ).to be_falsey

    waive

    agent_run.reload
    expect(agent_run.status).to eq("completed")
    expect(agent_run.result_commit_sha).to eq(shipped_commit)
    expect(agent_run.pull_request_url).to eq("https://github.com/example/pull/7")
    expect(agent_run.pull_request_number).to eq(7)
  end

  it "leaves runs without a withheld completion untouched" do
    waive

    expect(agent_run.reload.status).to eq("running")
  end
end
