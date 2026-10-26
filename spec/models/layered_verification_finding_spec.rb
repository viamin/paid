# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "deduplicates only the same scoped cause" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:)
    audit = create(:agent_run, project:, issue: nil, goal: "layered_verification_audit")
    create(:layered_verification_finding, project:, obligation:, originating_audit_run: audit,
      correspondence_claim_type: "spec_to_code", cause_signature: "missing-refund-transition")

    duplicate = build(:layered_verification_finding, project:, obligation:, originating_audit_run: audit,
      correspondence_claim_type: "spec_to_code", cause_signature: "missing-refund-transition")

    expect(duplicate).not_to be_valid
  end
end
