# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "attaches repeated observations to one unresolved scoped cause" do
    run = create(:agent_run, goal: "layered_verification_audit", issue: nil,
      external_metadata: { "layered_verification_audit" => { "obligation_ids" => [ 1 ] } })
    obligation = create(:layered_verification_obligation, project: run.project)
    result = create(:layered_verification_check_result, obligation:, agent_run: run)
    attributes = { observed_behavior: "Observed behavior", check_limitations: "Bounded evidence", question: "What should happen?" }

    first = described_class.record!(agent_run: run, obligation:, correspondence_claim_type: "business_to_spec",
      cause_signature: "cancel-retry", attributes:, check_result: result)
    second = described_class.record!(agent_run: run, obligation:, correspondence_claim_type: "business_to_spec",
      cause_signature: "cancel-retry", attributes:, check_result: result)

    expect(second.id).to eq(first.id)
    expect(second.observations.size).to eq(2)
  end
end
