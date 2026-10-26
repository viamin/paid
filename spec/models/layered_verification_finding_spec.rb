# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "attaches repeated observations to the unresolved scoped cause" do
    obligation = create(:layered_verification_obligation, external_identity: "PAYMENTS-001")
    run = create(:agent_run, project: obligation.project, goal: "layered_verification_audit")

    first = described_class.record!(obligation:, correspondence_claim: nil, cause_signature: "missing-model-link",
      observation: { "source" => "docs/intent/payments.md" }, agent_run: run)
    second = described_class.record!(obligation:, correspondence_claim: nil, cause_signature: "missing-model-link",
      observation: { "source" => "docs/intent/payments.md" }, agent_run: run)

    expect(second).to eq(first)
    expect(first.reload.observations.size).to eq(2)
  end
end
