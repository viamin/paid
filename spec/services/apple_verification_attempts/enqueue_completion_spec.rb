# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-011
# @spec APPLE-ATTEMPT-013
RSpec.describe AppleVerificationAttempts::EnqueueCompletion do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:agent_run) { create(:agent_run, :with_git_context, project:, status: "running") }
  let(:commit_sha) { "abc123def456789012345678901234567890abcd" }

  def approve_completion_workflow(required_checks: [ "test" ])
    workflow = create(
      :apple_verification_workflow_revision,
      project:,
      account:,
      lifecycle_gate: "completion_verification",
      required_checks:
    )
    administrator = create(:user, account:)
    administrator.add_role(:project_admin, project)
    workflow.approve!(actor: administrator)
    workflow
  end

  it "queues one attempt for the exact completed commit and schedules maintenance" do
    workflow = approve_completion_workflow

    expect {
      described_class.call(agent_run:, commit_sha:)
    }.to change(AppleVerificationAttempt, :count).by(1)
      .and have_enqueued_job(AppleVerificationAttemptMaintenanceJob)

    attempt = AppleVerificationAttempt.last
    expect(attempt).to have_attributes(
      account:,
      project:,
      agent_run:,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: workflow.apple_worker_profile,
      commit_sha:,
      source_digest: "sha256:#{Digest::SHA256.hexdigest(commit_sha)}",
      lifecycle_gate: "completion_verification",
      status: "queued",
      retry_number: 0
    )
  end

  it "does not queue duplicate attempts when completion is retried" do
    approve_completion_workflow

    described_class.call(agent_run:, commit_sha:)

    expect {
      described_class.call(agent_run:, commit_sha:)
    }.not_to change(AppleVerificationAttempt, :count)
  end

  it "does not queue an attempt for an advisory workflow" do
    approve_completion_workflow(required_checks: [])

    expect {
      described_class.call(agent_run:, commit_sha:)
    }.not_to change(AppleVerificationAttempt, :count)
  end
end
