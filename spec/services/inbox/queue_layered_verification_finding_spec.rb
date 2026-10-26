# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::Queue do
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  it "shows unresolved audit findings without treating a deferral as resolution" do
    project = create(:project)
    user = project.created_by
    obligation = create(:layered_verification_obligation, project:)
    finding = LayeredVerificationFinding.record!(
      project:, obligation:, correspondence_claim_type: "business_to_spec", cause_signature: "contradicted:semantic_audit",
      observation: { observed_behavior: "Code accepts an expired grant.", limitations: "No model was declared.", source_passages: {} }
    )
    finding.update!(state: "deferred", deferral_reason: "Awaiting owner decision")

    entries = described_class.new(user:, project:, kind: described_class::LAYERED_VERIFICATION_FINDING_KIND).call

    expect(entries.map(&:record)).to include(finding)
    expect(finding.reload.state).to eq("deferred")
  end
end
