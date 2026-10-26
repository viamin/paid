# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "deduplicates only the same scoped cause" do
    obligation = create(:layered_verification_obligation)
    run = create(:agent_run, project: obligation.project, goal: "layered_verification_audit", issue: nil)
    attributes = {
      project: obligation.project, obligation:, originating_audit_run: run,
      correspondence_claim_type: "spec_to_code", cause_signature: "retry-ordering-mismatch",
      source_passages: "The source requires FIFO.", observed_behavior: "The code retries out of order.",
      decision_question: "Which ordering is authoritative?"
    }

    described_class.create!(attributes)

    expect(described_class.new(attributes)).not_to be_valid
    expect(described_class.new(attributes.merge(cause_signature: "ownership-mismatch"))).to be_valid
  end
end
