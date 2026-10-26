# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "attaches repeated observations to the same unresolved scoped cause" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project)
    result = create(:layered_verification_check_result, obligation:, agent_run: audit)
    repeated_result = create(:layered_verification_check_result, obligation:, agent_run: audit)
    attributes = { source_passages: "source", observed_behavior: "observed", question: "Which is intended?", limitations: "bounded evidence" }

    first = described_class.record!(project: audit.project, obligation:, audit_run: audit, correspondence_claim_type: "spec_to_code", cause_signature: "retry-order", attributes:, check_result: result)
    second = described_class.record!(project: audit.project, obligation:, audit_run: audit, correspondence_claim_type: "spec_to_code", cause_signature: "retry-order", attributes:, check_result: repeated_result)

    expect(second).to eq(first)
    expect(first.observations.count).to eq(2)
  end
end
