# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::TimeoutMonitor do
  # @spec APPLE-ATTEMPT-004

  it "times out a running attempt whose started_at is beyond the timeout" do
    travel_to(Time.current) do
      attempt = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)
      complete = spy

      result = described_class.call(complete: complete)

      expect(result.timed_out).to eq(1)
      expect(result.scanned).to eq(1)
      expect(complete).to have_received(:call).with(
        attempt: attempt,
        outcome: "timed_out",
        failure_classification: "cancellation_or_timeout"
      )
    end
  end

  it "does not complete a running attempt started within the timeout" do
    travel_to(Time.current) do
      create(:apple_verification_attempt, status: "running", started_at: 10.minutes.ago)
      complete = spy

      result = described_class.call(complete: complete)

      expect(result.timed_out).to eq(0)
      expect(result.scanned).to eq(1)
      expect(complete).not_to have_received(:call)
    end
  end

  it "does not scan a queued attempt regardless of age" do
    travel_to(Time.current) do
      create(:apple_verification_attempt, status: "queued", started_at: 60.minutes.ago)
      complete = spy

      result = described_class.call(complete: complete)

      expect(result.timed_out).to eq(0)
      expect(result.scanned).to eq(0)
      expect(complete).not_to have_received(:call)
    end
  end

  it "falls back to created_at when started_at is nil" do
    travel_to(Time.current) do
      attempt = create(:apple_verification_attempt, status: "provisioning", created_at: 46.minutes.ago)
      complete = spy

      result = described_class.call(complete: complete)

      expect(result.timed_out).to eq(1)
      expect(result.scanned).to eq(1)
      expect(complete).to have_received(:call).with(
        attempt: attempt,
        outcome: "timed_out",
        failure_classification: "cancellation_or_timeout"
      )
    end
  end

  it "times out only the stale attempts among many scanned" do
    travel_to(Time.current) do
      stale = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)
      fresh = create(:apple_verification_attempt, status: "running", started_at: 10.minutes.ago)
      complete = spy

      result = described_class.call(complete: complete)

      expect(result.timed_out).to eq(1)
      expect(result.scanned).to eq(2)
      expect(complete).to have_received(:call).with(
        attempt: stale,
        outcome: "timed_out",
        failure_classification: "cancellation_or_timeout"
      )
      expect(complete).not_to have_received(:call).with(hash_including(attempt: fresh))
    end
  end

  it "does not time out an attempt cancelled before the completion lock is acquired" do
    travel_to(Time.current) do
      attempt = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)
      complete = spy
      active_attempts = instance_double(ActiveRecord::Relation)

      allow(AppleVerificationAttempt).to receive(:where).with(status: described_class::ACTIVE_STATUSES).and_return(active_attempts)
      allow(active_attempts).to receive(:find_each).and_yield(attempt)
      allow(attempt).to receive(:with_lock) do |&block|
        attempt.update!(status: "cancelled")
        block.call
      end

      result = described_class.call(complete: complete)

      expect(result.timed_out).to eq(0)
      expect(result.scanned).to eq(1)
      expect(complete).not_to have_received(:call)
    end
  end
end
