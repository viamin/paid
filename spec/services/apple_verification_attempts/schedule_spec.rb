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
  let(:lifecycle) { instance_double(AppleVerification::Lifecycle, provision: nil) }

  before { FeatureFlags.enable!(:apple_verification_workers, project:) }

  after { FeatureFlags.disable!(:apple_verification_workers, project:) }

  it "validates, admits, and provisions the next fair-share queue entry" do
    attempt

    result = described_class.call(admission: ->(project:) { allowed_admission }, lifecycle:)

    expect(result).to have_attributes(attempt:, outcome: "provisioning", reason: nil)
    expect(attempt.reload).to be_provisioning
    expect(lifecycle).to have_received(:provision).with(
      agent_run:, image_id: attempt.apple_worker_profile.image_digest,
      profile_id: attempt.apple_worker_profile.name,
      request_id: "apple_verification_attempt:#{attempt.id}", apple_verification_attempt: attempt
    )
  end

  it "leaves an attempt queued when admission refuses capacity" do
    attempt
    denied_admission = AppleVerificationAttempts::Admission::Decision.new(
      allowed: false, reason: "active_vm_limit", figures: nil, thresholds: nil
    )

    result = described_class.call(admission: ->(project:) { denied_admission }, lifecycle:)

    expect(result).to have_attributes(attempt:, outcome: "deferred", reason: "active_vm_limit")
    expect(attempt.reload).to be_queued
    expect(lifecycle).not_to have_received(:provision)
  end

  it "fails validation before attempting admission or provisioning" do
    FeatureFlags.disable!(:apple_verification_workers, project:)
    attempt

    result = described_class.call(admission: ->(*) { raise "admission should not run" }, lifecycle:)

    expect(result).to have_attributes(attempt:, outcome: "rejected", reason: "policy_denied")
    expect(attempt.reload).to have_attributes(status: "failed", failure_classification: "network_policy")
    expect(lifecycle).not_to have_received(:provision)
  end
end
