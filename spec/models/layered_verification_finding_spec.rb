# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "attaches repeated observations to one unresolved scoped cause" do
    obligation = create(:layered_verification_obligation)
    audit_run = create(:agent_run, project: obligation.project, goal: "layered_verification_audit")
    attributes = {
      project: obligation.project, obligation:, audit_run:, correspondence_claim_type: "business_to_spec",
      cause_signature: "missing-ref", source_passages: "source", observed_behavior: "behavior",
      limitations: "limited", question: "decide", options: [], links: {}
    }

    first = described_class.record_observation!(**attributes)
    second = described_class.record_observation!(**attributes)

    expect(second).to eq(first)
    expect(first.observations.count).to eq(2)
  end
end
