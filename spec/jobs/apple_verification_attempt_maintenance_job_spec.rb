# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-004
# @spec APPLE-ATTEMPT-001
# @spec APPLE-ATTEMPT-003
# @spec APPLE-ATTEMPT-005
# @spec APPLE-ATTEMPT-014
# @spec APPLE-TRANSFER-006
# @spec APPLE-ATTEMPT-015
RSpec.describe AppleVerificationAttemptMaintenanceJob do
  let(:recovery_result) do
    AppleVerificationAttempts::Recovery::Result.new(scanned: 1, reclassified: [ 42 ], orphans: { enqueued: 0 })
  end

  let(:retention_result) do
    AppleVerification::Bundles::RetentionSweep::Result.new(bundles_deleted: 0, vms_revoked: 1, attempts_scanned: 1)
  end

  let(:scheduling_result) do
    AppleVerificationAttempts::Schedule::Result.new(attempt: nil, outcome: "empty", reason: nil)
  end

  before do
    allow(AppleVerificationAttempts::Recovery).to receive(:call).and_return(recovery_result)
    allow(AppleVerificationAttempts::Schedule).to receive(:call).and_return(scheduling_result)
    allow(AppleVerification::Bundles::RetentionSweep).to receive(:call).and_return(retention_result)
  end

  it "runs attempt recovery from the scheduled maintenance path" do
    described_class.perform_now

    expect(AppleVerificationAttempts::Recovery).to have_received(:call)
  end

  it "sweeps expired retained VMs from the scheduled maintenance path" do
    described_class.perform_now

    expect(AppleVerification::Bundles::RetentionSweep).to have_received(:call)
  end

  it "dispatches the next queued attempt from the scheduled maintenance path" do
    described_class.perform_now

    expect(AppleVerificationAttempts::Schedule).to have_received(:call)
  end

  it "records worker health from the scheduled maintenance path" do
    profile = create(:apple_worker_profile)
    lifecycle = instance_double(AppleVerification::Lifecycle)
    allow(AppleVerification::Lifecycle).to receive(:from_environment).and_return(lifecycle)
    allow(AppleVerificationAttempts::WorkerHealth).to receive(:call)

    described_class.perform_now

    expect(AppleVerificationAttempts::WorkerHealth).to have_received(:call).with(profile:, lifecycle:)
  end

  # @spec APPLE-ATTEMPT-002
  it "rechecks admission thresholds for active attempts without terminating them" do
    attempt = create(:apple_verification_attempt, status: "running", started_at: 1.minute.ago)
    decision = AppleVerificationAttempts::Admission::Decision.new(
      allowed: false, reason: "host_disk_low", figures: nil, thresholds: nil
    )
    allow(AppleVerificationAttempts::Admission).to receive(:recheck_admissions).and_return(decision)

    described_class.perform_now

    expect(AppleVerificationAttempts::Admission).to have_received(:recheck_admissions).with(project: attempt.project)
    expect(attempt.reload).to be_running
  end
end
