# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::WorkerHealth do
  # @spec APPLE-ATTEMPT-015
  describe ".record_failure!" do
    it "quarantines a fresh profile once the threshold is reached" do
      profile = create(:apple_worker_profile)

      2.times { described_class.record_failure!(profile:, reason: "host disk full") }
      expect(profile.reload).not_to be_quarantined

      described_class.record_failure!(profile:, reason: "host disk full")

      expect(profile.reload).to be_quarantined
      expect(profile).not_to be_available
      expect(profile.quarantine_reason).to eq("host disk full")
    end

    it "does not double-stamp quarantined_at on further failures" do
      profile = create(:apple_worker_profile)
      3.times { described_class.record_failure!(profile:, reason: "worker crash") }

      original_stamp = profile.reload.quarantined_at

      result = described_class.record_failure!(profile:, reason: "worker crash")

      expect(result.quarantined).to be(true)
      expect(result.consecutive_health_failures).to eq(4)
      expect(profile.reload.quarantined_at).to eq(original_stamp)
      expect(profile).to be_quarantined
    end

    it "re-quarantines a profile that fails again after returning to service" do
      profile = create(:apple_worker_profile)
      3.times { described_class.record_failure!(profile:, reason: "worker crash") }
      described_class.return_to_service!(profile:, smoke_test_passed: true)
      expect(profile.reload).not_to be_quarantined

      2.times { described_class.record_failure!(profile:, reason: "host disk full") }
      expect(profile.reload).not_to be_quarantined

      result = described_class.record_failure!(profile:, reason: "host disk full")

      expect(result.quarantined).to be(true)
      expect(profile.reload).to be_quarantined
      expect(profile).not_to be_available
      expect(profile.quarantine_reason).to eq("host disk full")
    end
  end

  # @spec APPLE-ATTEMPT-015
  describe ".record_success!" do
    it "resets the counter but leaves a quarantined profile quarantined" do
      profile = create(:apple_worker_profile)
      3.times { described_class.record_failure!(profile:, reason: "worker crash") }

      result = described_class.record_success!(profile:)

      expect(result.quarantined).to be(true)
      expect(result.consecutive_health_failures).to eq(0)
      expect(profile.reload).to be_quarantined
      expect(profile.consecutive_health_failures).to eq(0)
    end
  end

  # @spec APPLE-ATTEMPT-015
  describe ".return_to_service!" do
    it "raises unless the smoke test passed" do
      profile = create(:apple_worker_profile)

      expect {
        described_class.return_to_service!(profile:, smoke_test_passed: false)
      }.to raise_error(ArgumentError, "isolation smoke test must pass before returning worker to service")
    end

    it "clears quarantine when the smoke test passes" do
      profile = create(:apple_worker_profile)
      3.times { described_class.record_failure!(profile:, reason: "worker crash") }

      result = described_class.return_to_service!(profile:, smoke_test_passed: true)

      expect(result.quarantined).to be(false)
      expect(result.consecutive_health_failures).to eq(0)
      expect(profile.reload).not_to be_quarantined
      expect(profile).to be_available
      expect(profile.last_smoke_test_passed_at).not_to be_nil
    end
  end

  # @spec APPLE-ATTEMPT-015
  describe ".quarantined?" do
    it "delegates to the profile" do
      profile = create(:apple_worker_profile)

      expect(described_class.quarantined?(profile:)).to be(false)

      profile.update!(quarantined_at: Time.current)
      expect(described_class.quarantined?(profile:)).to be(true)
    end
  end
end
