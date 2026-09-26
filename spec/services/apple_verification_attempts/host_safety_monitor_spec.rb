# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::HostSafetyMonitor do
  # @spec APPLE-ATTEMPT-002

  let(:lifecycle) { instance_double(AppleVerification::Lifecycle) }
  let(:complete) { spy }

  def capacity_sampler(free_host_disk_gib: 0, critical_memory_samples: 0)
    snapshot = AppleVerificationAttempts::HostCapacity::Snapshot.new(
      capacity: { free_host_disk_gib: },
      critical_memory_samples:
    )
    instance_double(AppleVerificationAttempts::HostCapacity, host_safety_snapshot: snapshot)
  end

  it "does not terminate when the host is safe" do
    create(:apple_verification_attempt, status: "running")
    sampler = capacity_sampler(free_host_disk_gib: 60, critical_memory_samples: 0)

    result = described_class.call(capacity_sampler: sampler, lifecycle:, complete:)

    expect(result.terminated).to eq(0)
    expect(result.scanned).to eq(0)
    expect(complete).not_to have_received(:call)
  end

  it "terminates running and provisioning attempts on a host-safety violation" do
    running = create(:apple_verification_attempt, status: "running")
    provisioning = create(:apple_verification_attempt, status: "provisioning")
    sampler = capacity_sampler(free_host_disk_gib: 0, critical_memory_samples: 0)

    result = described_class.call(capacity_sampler: sampler, lifecycle:, complete:)

    expect(result.terminated).to eq(2)
    expect(result.scanned).to eq(2)
    expect(complete).to have_received(:call).with(
      attempt: running,
      outcome: "unavailable",
      failure_classification: "worker_infrastructure",
      lifecycle: lifecycle,
      terminate_vm: true
    )
    expect(complete).to have_received(:call).with(
      attempt: provisioning,
      outcome: "unavailable",
      failure_classification: "worker_infrastructure",
      lifecycle: lifecycle,
      terminate_vm: true
    )
  end

  it "does not terminate an attempt cancelled before the completion lock is acquired" do
    attempt = create(:apple_verification_attempt, status: "running")
    sampler = capacity_sampler(free_host_disk_gib: 0, critical_memory_samples: 0)
    active_attempts = instance_double(ActiveRecord::Relation)

    allow(AppleVerificationAttempt).to receive(:where).with(status: described_class::ACTIVE_STATUSES).and_return(active_attempts)
    allow(active_attempts).to receive(:exists?).and_return(true)
    allow(active_attempts).to receive(:find_each).and_yield(attempt)
    allow(attempt).to receive(:with_lock) do |&block|
      attempt.update!(status: "cancelled")
      block.call
    end

    result = described_class.call(capacity_sampler: sampler, lifecycle:, complete:)

    expect(result.terminated).to eq(0)
    expect(result.scanned).to eq(1)
    expect(complete).not_to have_received(:call)
  end

  it "does nothing when the capacity sampler is nil" do
    create(:apple_verification_attempt, status: "running")

    result = described_class.call(capacity_sampler: nil, lifecycle:, complete:)

    expect(result.terminated).to eq(0)
    expect(result.scanned).to eq(0)
    expect(complete).not_to have_received(:call)
  end

  it "does nothing when the host safety snapshot is nil" do
    create(:apple_verification_attempt, status: "running")
    sampler = instance_double(AppleVerificationAttempts::HostCapacity, host_safety_snapshot: nil)

    result = described_class.call(capacity_sampler: sampler, lifecycle:, complete:)

    expect(result.terminated).to eq(0)
    expect(result.scanned).to eq(0)
    expect(complete).not_to have_received(:call)
  end

  it "does not sample the host when no active attempts exist" do
    create(:apple_verification_attempt, status: "queued")
    sampler = instance_double(AppleVerificationAttempts::HostCapacity, host_safety_snapshot: nil)

    result = described_class.call(capacity_sampler: sampler, lifecycle:, complete:)

    expect(result.terminated).to eq(0)
    expect(result.scanned).to eq(0)
    expect(sampler).not_to have_received(:host_safety_snapshot)
  end
end
