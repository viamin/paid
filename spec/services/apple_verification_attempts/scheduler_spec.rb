# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Scheduler do
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-015
  let(:capacity) do
    -> {
      AppleVerificationAttempts::CapacitySnapshot.new(
        free_host_disk_bytes: 61.gigabytes,
        free_memory_fraction: 0.26,
        free_guest_disk_bytes: 16.gigabytes,
        critical_memory_pressure: false
      )
    }
  end
  let(:dispatched) { [] }
  let(:dispatcher) { ->(attempt) { dispatched << attempt } }

  def enable_verification!(attempt)
    attempt.project.update!(apple_verification_mode: "on_demand")
    FeatureFlags.enable!(:apple_verification_workers, project: attempt.project)
  end

  it "admits the fair queue head and hands it to the dispatcher" do
    attempt = create(:apple_verification_attempt)
    enable_verification!(attempt)

    result = described_class.call(capacity:, dispatcher:)

    expect(result).to be_admitted
    expect(result.attempt).to eq(attempt)
    expect(dispatched).to eq([ attempt ])
    expect(attempt.reload.status).to eq("provisioning")
  end

  it "keeps a quarantined worker's head queued while admitting the next healthy candidate" do
    quarantined = create(:apple_verification_attempt)
    healthy = create(:apple_verification_attempt)
    enable_verification!(quarantined)
    enable_verification!(healthy)
    AppleVerificationWorkerHealth.create!(apple_worker_profile: quarantined.apple_worker_profile, status: "quarantined", quarantined_at: Time.current)

    result = described_class.call(capacity:, dispatcher:)

    expect(result).to be_admitted
    expect(result.attempt).to eq(healthy)
    expect(quarantined.reload.status).to eq("queued")
    expect(healthy.reload.status).to eq("provisioning")
    expect(dispatched).to eq([ healthy ])
  end

  it "stops at a queue-wide deferral instead of skipping past it" do
    create(:apple_verification_attempt, status: "running")
    head = create(:apple_verification_attempt)
    follower = create(:apple_verification_attempt)
    enable_verification!(head)
    enable_verification!(follower)

    result = described_class.call(capacity:, dispatcher:)

    expect(result).to be_deferred
    expect(result.reason).to eq("active VM limit reached")
    expect(head.reload.status).to eq("queued")
    expect(follower.reload.status).to eq("queued")
    expect(dispatched).to be_empty
  end

  it "reports the quarantine deferral when every queued attempt waits on a quarantined worker" do
    first = create(:apple_verification_attempt)
    second = create(:apple_verification_attempt)
    enable_verification!(first)
    enable_verification!(second)
    [ first, second ].each do |attempt|
      AppleVerificationWorkerHealth.create!(apple_worker_profile: attempt.apple_worker_profile, status: "quarantined", quarantined_at: Time.current)
    end

    result = described_class.call(capacity:, dispatcher:)

    expect(result).to be_deferred
    expect(result.reason).to eq("worker is quarantined")
    expect(first.reload.status).to eq("queued")
    expect(second.reload.status).to eq("queued")
    expect(dispatched).to be_empty
  end

  it "returns nil without probing host capacity when the queue is empty" do
    probe = -> { raise "host capacity must not be probed for an empty queue" }

    expect(described_class.call(capacity: probe, dispatcher: dispatcher)).to be_nil
    expect(dispatched).to be_empty
  end
end
