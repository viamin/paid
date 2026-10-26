# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "deduplicates the same scoped cause without merging a distinct cause" do
    first = create(:layered_verification_finding)
    duplicate = build(:layered_verification_finding, project: first.project, obligation: first.obligation,
      correspondence_claim_type: first.correspondence_claim_type, cause_signature: first.cause_signature)
    distinct = build(:layered_verification_finding, project: first.project, obligation: first.obligation,
      correspondence_claim_type: first.correspondence_claim_type, cause_signature: "other-cause")

    expect(duplicate).not_to be_valid
    expect(distinct).to be_valid
  end
end
