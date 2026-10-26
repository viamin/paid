# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "deduplicates only an unresolved finding with the same scoped cause" do
    obligation = create(:layered_verification_obligation)
    attributes = { obligation:, correspondence_claim_type: "spec_to_code", cause_signature: "retry-ordering", source_passages: [ "SPEC-1" ], observed_behavior: "retries out of order", limitations: "static observation" }

    finding = described_class.record!(**attributes, observation: { "check_result_id" => 1 })
    repeated = described_class.record!(**attributes.merge(observed_behavior: "same cause, new revision"), observation: { "check_result_id" => 2 })

    expect(repeated).to eq(finding)
    expect(finding.reload.observations).to include({ "check_result_id" => 1 }, { "check_result_id" => 2 })
  end
end
