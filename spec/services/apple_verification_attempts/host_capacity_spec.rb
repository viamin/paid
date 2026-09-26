# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::HostCapacity do
  # @spec APPLE-ATTEMPT-001
  let(:configuration) do
    AppleVerificationAttempts::Configuration.new(
      minimum_host_disk_bytes: 60.gigabytes,
      minimum_guest_disk_bytes: 15.gigabytes
    )
  end

  before do
    ENV["APPLE_VERIFICATION_HOST_URL"] = "https://macos-worker.internal/lifecycle"
    ENV["APPLE_VERIFICATION_HOST_TOKEN"] = "token"
  end

  after do
    ENV.delete("APPLE_VERIFICATION_HOST_URL")
    ENV.delete("APPLE_VERIFICATION_HOST_TOKEN")
  end

  def stub_readiness(payload)
    client = instance_double(AppleVerification::HostClient)
    allow(AppleVerification::HostClient).to receive(:new).and_return(client)
    allow(client).to receive(:call).and_return(payload)
  end

  it "reads the documented host payload and projects guest disk beyond the reserved host minimum" do
    stub_readiness({
      "cpu" => { "available_cores" => 10 },
      "memory" => { "free_percent" => 47, "pressure" => "nominal" },
      "disk" => { "free_gib" => 80 },
      "images" => [], "network" => {}, "guest_connection" => {}
    })

    snapshot = described_class.new(configuration:).call

    expect(snapshot).to have_attributes(
      free_host_disk_bytes: 80.gigabytes,
      free_memory_fraction: 0.47,
      free_guest_disk_bytes: 20.gigabytes,
      critical_memory_pressure: false
    )
  end

  it "marks critical memory pressure from the readiness payload" do
    stub_readiness("memory" => { "free_percent" => 47, "pressure" => "critical" }, "disk" => { "free_gib" => 80 })

    expect(described_class.new(configuration:).call.critical_memory_pressure).to be(true)
  end

  it "supports byte readings and flat fallback keys" do
    stub_readiness("disk_free_bytes" => 90.gigabytes, "memory_free_fraction" => 0.5)

    snapshot = described_class.new(configuration:).call

    expect(snapshot).to have_attributes(
      free_host_disk_bytes: 90.gigabytes,
      free_memory_fraction: 0.5,
      free_guest_disk_bytes: 30.gigabytes
    )
  end

  it "fails closed when the payload carries no disk reading" do
    stub_readiness("memory" => { "free_percent" => 47 })

    snapshot = described_class.new(configuration:).call

    expect(snapshot.free_host_disk_bytes).to eq(0)
    expect(snapshot.free_guest_disk_bytes).to be < configuration.minimum_guest_disk_bytes
  end

  it "fails closed when the payload carries no memory reading" do
    stub_readiness("disk" => { "free_gib" => 80 })

    snapshot = described_class.new(configuration:).call

    expect(snapshot.free_memory_fraction).to eq(0)
  end

  it "projects a guest disk that falls short of the guest minimum while the host reading passes" do
    stub_readiness("disk" => { "free_gib" => 70 })

    snapshot = described_class.new(configuration:).call

    expect(snapshot.free_host_disk_bytes).to be >= configuration.minimum_host_disk_bytes
    expect(snapshot.free_guest_disk_bytes).to eq(10.gigabytes)
    expect(snapshot.free_guest_disk_bytes).to be < configuration.minimum_guest_disk_bytes
  end
end
