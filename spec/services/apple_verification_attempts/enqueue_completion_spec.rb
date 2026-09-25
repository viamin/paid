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

  it "does not enable a required completion gate until execution is available" do
    workflow = approve_completion_workflow

    expect {
      described_class.call(agent_run:, commit_sha:)
    }.not_to change(AppleVerificationAttempt, :count)
    expect(workflow).to be_approved
    expect(AppleVerificationAttemptMaintenanceJob).not_to have_been_enqueued
  end

  it "does not queue attempts when completion is retried" do
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
