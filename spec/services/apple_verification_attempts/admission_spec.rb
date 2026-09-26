# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Admission do
  # @spec APPLE-ATTEMPT-001
  let(:attempt) { create(:apple_verification_attempt) }
  let(:capacity) do
    AppleVerificationAttempts::CapacitySnapshot.new(
      free_host_disk_bytes: 61.gigabytes,
      free_memory_fraction: 0.26,
      free_guest_disk_bytes: 16.gigabytes,
      critical_memory_pressure: false
    )
  end

  before do
    attempt.project.update!(apple_verification_mode: "on_demand")
    FeatureFlags.enable!(:apple_verification_workers, project: attempt.project)
  end

  it "reserves the single worker slot when capacity passes" do
    result = described_class.call(attempt:, capacity:)

    expect(result).to be_admitted
    expect(attempt.reload).to have_attributes(status: "provisioning", admission_reserved_at: be_present)
  end

  it "reports capacity refusal as infrastructure rather than a code failure" do
    limited_capacity = capacity.with(free_host_disk_bytes: 59.gigabytes)

    result = described_class.call(attempt:, capacity: limited_capacity)

    expect(result).not_to be_admitted
    expect(attempt.reload).to have_attributes(status: "unavailable", failure_classification: "capacity_or_quota")
  end

  it "leaves the queued attempt in place while the active worker slot is occupied" do
    create(:apple_verification_attempt, status: "running")

    result = described_class.call(attempt:, capacity:)

    expect(result).to be_deferred
    expect(attempt.reload).to have_attributes(status: "queued", failure_classification: nil)
  end
end
