# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Scheduler do
  # @spec APPLE-ATTEMPT-003
  let(:capacity) do
    ->(attempt: _) {
      AppleVerificationAttempts::HostCapacity::Snapshot.new(
        capacity: {
          free_host_disk_gib: 61,
          free_memory_percent: 26,
          free_guest_disk_gib: 16
        },
        critical_memory_samples: 0
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
    expect(dispatched).to eq([ attempt ])
    expect(attempt.reload.status).to eq("queued")
  end

  it "defers its fair queue head when the active VM limit is reached" do
    create(:apple_verification_attempt, status: "running")
    head = create(:apple_verification_attempt)
    follower = create(:apple_verification_attempt)
    enable_verification!(head)
    enable_verification!(follower)

    result = described_class.call(capacity:, dispatcher:)

    expect(result).not_to be_admitted
    expect(result.reason).to eq("active VM limit reached")
    expect(head.reload.status).to eq("queued")
    expect(follower.reload.status).to eq("queued")
    expect(dispatched).to be_empty
  end

  it "returns nil without probing host capacity when the queue is empty" do
    probe = -> { raise "host capacity must not be probed for an empty queue" }

    expect(described_class.call(capacity: probe, dispatcher: dispatcher)).to be_nil
    expect(dispatched).to be_empty
  end
end
