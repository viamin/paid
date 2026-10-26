# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  it "deduplicates by scoped cause, not text" do
    obligation = create(:layered_verification_obligation)
    attributes = { project: obligation.project, obligation:, correspondence_claim_type: "business_to_model",
                   cause_signature: "missing-refund-transition", source_passages: "source", observed_behavior: "code",
                   decision_question: "Which behavior is intended?" }
    create(:layered_verification_finding, **attributes)

    duplicate = build(:layered_verification_finding, **attributes)

    expect(duplicate).not_to be_valid
  end

  it "attaches repeated observations to the unresolved finding" do
    obligation = create(:layered_verification_obligation)
    claim = create(:layered_verification_correspondence_claim, obligation:)
    result = create(:layered_verification_check_result, obligation:, correspondence_claim: claim)
    attributes = { source_passages: "source", observed_behavior: "code", decision_question: "Which behavior is intended?" }

    finding = LayeredVerification::Findings::Record.call(project: obligation.project, obligation:, correspondence_claim: claim,
      cause_signature: "missing-refund-transition", check_result: result, attributes:)
    duplicate = LayeredVerification::Findings::Record.call(project: obligation.project, obligation:, correspondence_claim: claim,
      cause_signature: "missing-refund-transition", check_result: result, attributes:)

    expect(duplicate).to eq(finding)
    expect(finding.reload.observations.size).to eq(2)
  end
end
