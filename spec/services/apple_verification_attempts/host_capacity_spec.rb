# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::HostCapacity do
  # @spec APPLE-ATTEMPT-001
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:attempt) { create(:apple_verification_attempt, project:, account:) }
  let(:host) { instance_double(AppleVerification::HostClient) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:readiness) do
    {
      "memory" => { "free_percent" => 50, "pressure" => "nominal" },
      "disk" => { "free_gib" => 100 }
    }
  end

  before do
    create(:apple_verification_image, :active, account:, digest: attempt.apple_worker_profile.image_digest, resources: {
      "cpu_count" => 4, "memory_gib" => 8, "disk_gib" => 20
    })
    allow(host).to receive(:call).and_return(readiness)
  end

  it "maps host readiness and the schedulable image disk envelope into admission capacity" do
    snapshot = described_class.new(host:, token: "test-token", cache:).call(attempt:)

    expect(snapshot).to have_attributes(
      capacity: { free_host_disk_gib: 100.0, free_memory_percent: 50.0, free_guest_disk_gib: 20.0 },
      critical_memory_samples: 0
    )
  end

  it "counts consecutive critical memory samples and resets the count after recovery" do
    readiness["memory"]["pressure"] = "critical"
    sampler = described_class.new(host:, token: "test-token", cache:)

    expect(sampler.call(attempt:).critical_memory_samples).to eq(1)
    expect(sampler.call(attempt:).critical_memory_samples).to eq(2)

    readiness["memory"]["pressure"] = "nominal"

    expect(sampler.call(attempt:).critical_memory_samples).to eq(0)
  end

  it "returns nil when the readiness payload is missing the memory field" do
    allow(host).to receive(:call).and_return("disk" => { "free_gib" => 100 })

    expect(described_class.new(host:, token: "test-token", cache:).call(attempt:)).to be_nil
  end

  it "returns nil when the readiness payload is missing the disk field" do
    allow(host).to receive(:call).and_return("memory" => { "free_percent" => 50, "pressure" => "nominal" })

    expect(described_class.new(host:, token: "test-token", cache:).call(attempt:)).to be_nil
  end

  it "returns nil when the readiness payload is not an object" do
    allow(host).to receive(:call).and_return(%w[unexpected])

    expect(described_class.new(host:, token: "test-token", cache:).call(attempt:)).to be_nil
  end

  it "returns a nil host-safety snapshot when the readiness payload is missing the disk field" do
    allow(host).to receive(:call).and_return("memory" => { "pressure" => "nominal" })

    expect(described_class.new(host:, token: "test-token", cache:).host_safety_snapshot).to be_nil
  end

  it "returns a nil host-safety snapshot when the readiness payload is not an object" do
    allow(host).to receive(:call).and_return("unexpected")

    expect(described_class.new(host:, token: "test-token", cache:).host_safety_snapshot).to be_nil
  end

  it "returns a nil host-safety snapshot when memory is malformed" do
    allow(host).to receive(:call).and_return(
      "memory" => "unknown",
      "disk" => { "free_gib" => 100 }
    )

    expect(described_class.new(host:, token: "test-token", cache:).host_safety_snapshot).to be_nil
  end
end
