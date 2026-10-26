# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "deduplicates matching unresolved causes while preserving observations" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project)
    result = create(:layered_verification_check_result, obligation: obligation, agent_run: audit)

    finding = described_class.record!(audit_run: audit, obligation: obligation, check_result: result,
      cause_signature: "missing-payment-authorization", detail: { "claim" => "authorization is required" })
    repeated = described_class.record!(audit_run: audit, obligation: obligation, check_result: result,
      cause_signature: "missing-payment-authorization", detail: { "claim" => "authorization is required" })

    expect(repeated).to eq(finding)
    expect(finding.observations.count).to eq(2)
  end
end
