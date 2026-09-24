# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-001
# @spec APPLE-ATTEMPT-003
# @spec APPLE-ATTEMPT-005
RSpec.describe AppleVerificationAttempts::Schedule do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:agent_run) { create(:agent_run, project:) }
  let(:attempt) { create(:apple_verification_attempt, project:, account:, agent_run:) }
  let(:allowed_admission) do
    AppleVerificationAttempts::Admission::Decision.new(allowed: true, reason: "allowed", figures: nil, thresholds: nil)
  end

  before { FeatureFlags.enable!(:apple_verification_workers, project:) }

  after { FeatureFlags.disable!(:apple_verification_workers, project:) }

  it "keeps an admitted attempt queued until verification execution is available" do
    attempt

    result = described_class.call(admission: ->(project:) { allowed_admission })

    expect(result).to have_attributes(attempt:, outcome: "deferred", reason: "verification_execution_unavailable")
    expect(attempt.reload).to be_queued
  end

  it "leaves an attempt queued when admission refuses capacity" do
    attempt
    denied_admission = AppleVerificationAttempts::Admission::Decision.new(
      allowed: false, reason: "active_vm_limit", figures: nil, thresholds: nil
    )

    result = described_class.call(admission: ->(project:) { denied_admission })

    expect(result).to have_attributes(attempt:, outcome: "deferred", reason: "active_vm_limit")
    expect(attempt.reload).to be_queued
  end

  it "fails validation before attempting admission or provisioning" do
    FeatureFlags.disable!(:apple_verification_workers, project:)
    attempt

    result = described_class.call(admission: ->(*) { raise "admission should not run" })

    expect(result).to have_attributes(attempt:, outcome: "rejected", reason: "policy_denied")
    expect(attempt.reload).to have_attributes(status: "failed", failure_classification: "network_policy")
  end
end
