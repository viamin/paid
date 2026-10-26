# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "adds repeat evidence to the same unresolved cause without merging a distinct cause" do
    obligation = create(:layered_verification_obligation)
    first = described_class.record!(project: obligation.project, obligation:, correspondence_claim_type: "business_to_spec", cause_signature: "missing-refund-rule", evidence: {}, revision: "one")
    repeat = described_class.record!(project: obligation.project, obligation:, correspondence_claim_type: "business_to_spec", cause_signature: "missing-refund-rule", evidence: {}, revision: "two")
    distinct = described_class.record!(project: obligation.project, obligation:, correspondence_claim_type: "business_to_spec", cause_signature: "wrong-currency", evidence: {}, revision: "two")

    expect(repeat).to eq(first)
    expect(first.observations.count).to eq(2)
    expect(distinct).not_to eq(first)
  end
end
