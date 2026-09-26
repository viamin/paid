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

  it "resets prior worker health failures after provisioning succeeds" do
    revision.apple_worker_profile.update!(
      consecutive_health_failures: 2,
      last_health_failure_at: 1.minute.ago
    )
    queued_attempt

    dispatch

    expect(revision.apple_worker_profile.reload.consecutive_health_failures).to eq(0)
  end

  it "records a worker health failure when provisioning fails" do
    attempt = queued_attempt
    allow(lifecycle).to receive(:provision).and_raise(
      AppleVerification::HostService::AuthenticationError,
      "unauthenticated"
    )

    result = dispatch

    expect(result).to have_attributes(started: 0, rejected: 1, skipped: false)
    expect(attempt.reload).to have_attributes(status: "unavailable", failure_classification: "worker_infrastructure")
    expect(revision.apple_worker_profile.reload).to have_attributes(
      consecutive_health_failures: 1,
      last_health_failure_at: be_present,
      quarantine_reason: nil
    )
  end

  it "quarantines a worker after repeated provisioning failures" do
    attempts = [ queued_attempt ]
    2.times { attempts << queued_attempt(agent_run: create(:agent_run, :running, project:)) }
    allow(lifecycle).to receive(:provision).and_raise(
      AppleVerification::HostService::AuthenticationError,
      "unauthenticated"
    )

    result = dispatch

    expect(result).to have_attributes(started: 0, rejected: 3, skipped: false)
    expect(revision.apple_worker_profile.reload).to be_quarantined
    expect(attempts.map { |attempt| attempt.reload.status }).to all(eq("unavailable"))
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
