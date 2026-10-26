# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "deduplicates only an identical scoped cause and retains new observations" do
    obligation = create(:layered_verification_obligation)
    first = described_class.record!(obligation:, correspondence_claim_type: "spec_to_code", cause_signature: "missing-retry-bound", observation: { "check_result_id" => 1 })
    repeated = described_class.record!(obligation:, correspondence_claim_type: "spec_to_code", cause_signature: "missing-retry-bound", observation: { "check_result_id" => 2 })

    expect(repeated).to eq(first)
    expect(first.reload.observations).to contain_exactly({ "check_result_id" => 1 }, { "check_result_id" => 2 })
  end
end
