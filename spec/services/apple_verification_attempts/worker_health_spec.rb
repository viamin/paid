# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::WorkerHealth do
  # @spec APPLE-ATTEMPT-015
  it "requires a passing isolation smoke test before a quarantined worker returns" do
    profile = create(:apple_worker_profile)
    service = described_class.new(profile:, configuration: AppleVerificationAttempts::Configuration.new(health_failure_limit: 2))

    2.times { service.record_failure }

    expect { service.return_to_service! }.to raise_error(ArgumentError, "a passing isolation smoke test is required")

    service.record_isolation_smoke_test!
    service.return_to_service!

    expect(AppleVerificationWorkerHealth.last).to be_healthy
  end

  it "revokes credentials for active attempts when it quarantines a worker" do
    attempt = create(:apple_verification_attempt, status: "running")
    profile = attempt.apple_worker_profile
    revoker = ->(attempt:) { }
    service = described_class.new(profile:, configuration: AppleVerificationAttempts::Configuration.new(health_failure_limit: 1), credential_revoker: revoker)

    expect(revoker).to receive(:call).with(attempt:)

    service.record_failure
  end
end
