# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Dispatcher do
  # @spec APPLE-ATTEMPT-001
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-005
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, apple_verification_mode: "on_demand") }
  let(:agent_run) { create(:agent_run, :running, project:) }
  let(:revision) { create(:apple_verification_workflow_revision, :approved, project:) }
  let(:snapshot) do
    AppleVerificationAttempts::HostCapacity::Snapshot.new(
      capacity: {
        free_host_disk_gib: 100,
        free_memory_percent: 50,
        free_guest_disk_gib: 20
      },
      critical_memory_samples: 0
    )
  end
  let(:capacity_sampler) { ->(_attempt) { snapshot } }
  let(:lifecycle) { instance_double(AppleVerification::Lifecycle, provision: instance_double(ExecutionRunners::RunnerHandle)) }

  before { FeatureFlags.enable!(:apple_verification_workers, project:) }

  def queued_attempt(project: self.project, agent_run: self.agent_run, revision: self.revision)
    create(
      :apple_verification_attempt,
      project:,
      account: project.account,
      agent_run:,
      apple_verification_workflow_revision: revision,
      apple_worker_profile: revision.apple_worker_profile,
      lifecycle_gate: revision.lifecycle_gate
    )
  end

  def dispatch
    described_class.call(capacity_sampler:, lifecycle:)
  end

  it "starts the fair queue head after admission" do
    attempt = queued_attempt

    result = dispatch

    expect(result).to have_attributes(started: 1, rejected: 0, skipped: false)
    expect(attempt.reload).to have_attributes(status: "running", started_at: be_present)
    expect(lifecycle).to have_received(:provision).with(
      agent_run:,
      image_id: revision.apple_worker_profile.image_digest,
      profile_id: revision.apple_worker_profile.name,
      request_id: "apple-verification-attempt:#{attempt.id}",
      apple_verification_attempt: attempt
    )
  end

  it "leaves the queue head queued when capacity refuses admission" do
    snapshot.capacity[:free_host_disk_gib] = 10
    attempt = queued_attempt

    result = dispatch

    expect(result).to have_attributes(started: 0, rejected: 0, skipped: true)
    expect(attempt.reload.status).to eq("queued")
    expect(lifecycle).not_to have_received(:provision)
  end

  it "removes an invalid queue head then starts the next fair attempt" do
    invalid_project = create(:project, account:, apple_verification_mode: "off")
    FeatureFlags.enable!(:apple_verification_workers, project: invalid_project)
    invalid_run = create(:agent_run, :running, project: invalid_project)
    invalid_revision = create(:apple_verification_workflow_revision, :approved, project: invalid_project)
    invalid_attempt = queued_attempt(project: invalid_project, agent_run: invalid_run, revision: invalid_revision)
    valid_attempt = queued_attempt

    result = dispatch

    expect(result).to have_attributes(started: 1, rejected: 1, skipped: false)
    expect(invalid_attempt.reload).to have_attributes(status: "failed", failure_classification: "project_configuration")
    expect(valid_attempt.reload.status).to eq("running")
  end
end
