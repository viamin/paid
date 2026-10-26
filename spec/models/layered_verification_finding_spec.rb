# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "uses the scoped cause identity and appends repeated observations" do
    finding = create(:layered_verification_finding)
    result = create(:layered_verification_check_result, obligation: finding.obligation)

    finding.record_observation!(check_result: result, observed_at: Time.zone.parse("2026-10-26 12:00:00 UTC"))

    expect(finding.reload.observations).to include(
      "check_result_id" => result.id,
      "observed_at" => Time.zone.parse("2026-10-26 12:00:00 UTC").iso8601
    )
    duplicate = build(:layered_verification_finding, project: finding.project, obligation: finding.obligation,
      correspondence_claim_type: finding.correspondence_claim_type, cause_signature: finding.cause_signature)
    expect(duplicate).not_to be_valid
  end
end
