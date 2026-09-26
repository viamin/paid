# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Config do
  # @spec APPLE-ATTEMPT-001
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-004

  around do |example|
    original = ENV.select { |key, _| key.start_with?("APPLE_VERIFICATION_") }
    example.run
  ensure
    (ENV.keys.grep(/\AAPPLE_VERIFICATION_/) - original.keys).each { |key| ENV.delete(key) }
    original.each { |key, value| ENV[key] = value }
  end

  it "exposes the admission capacity defaults" do
    expect(described_class.max_active_vms).to eq(1)
    expect(described_class.min_free_host_disk_gib).to eq(60)
    expect(described_class.min_free_memory_percent).to eq(25)
    expect(described_class.min_free_guest_disk_gib).to eq(15)
  end

  it "exposes the timeout and limit defaults" do
    expect(described_class.attempt_timeout_minutes).to eq(45)
    expect(described_class.max_queue_depth).to eq(100)
    expect(described_class.max_retries).to eq(3)
    expect(described_class.failed_vm_retention_hours).to eq(1)
    expect(described_class.max_attempts_per_run).to eq(3)
  end

  it "exposes the worker health and memory pressure defaults" do
    expect(described_class.worker_health_failure_threshold).to eq(3)
    expect(described_class.critical_memory_percent).to eq(10)
    expect(described_class.critical_memory_pressure_samples).to eq(3)
  end

  it "reads overrides from APPLE_VERIFICATION_* environment variables" do
    ENV["APPLE_VERIFICATION_MIN_FREE_HOST_DISK_GIB"] = "80"
    ENV["APPLE_VERIFICATION_ATTEMPT_TIMEOUT_MINUTES"] = "90"

    expect(described_class.min_free_host_disk_gib).to eq(80)
    expect(described_class.attempt_timeout_minutes).to eq(90)
  end

  it "raises when an environment override is not numeric" do
    ENV["APPLE_VERIFICATION_MAX_RETRIES"] = "plenty"

    expect { described_class.max_retries }.to raise_error(ArgumentError)
  end
end
