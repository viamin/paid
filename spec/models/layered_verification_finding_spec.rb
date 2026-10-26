# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "deduplicates only the same unresolved scoped cause" do
    obligation = create(:layered_verification_obligation)
    attributes = {
      project: obligation.project, obligation:, obligation_external_identity: obligation.external_identity,
      correspondence_claim_type: "business_to_spec", cause_signature: "missing-refund-branch",
      observed_behavior: "The refund branch is absent.", check_limitations: "Static evidence only.",
      question: "Which refund behavior is intended?"
    }
    described_class.create!(**attributes)

    expect(described_class.new(**attributes)).not_to be_valid
    expect(described_class.new(**attributes.merge(cause_signature: "missing-retry-branch"))).to be_valid
  end

  # @spec LAYERED-VERIFY-016
  it "keeps a deferred finding unresolved" do
    finding = create(:layered_verification_finding)

    finding.defer!(reason: "Awaiting a product decision")

    expect(finding).to have_attributes(state: "deferred", deferral_reason: "Awaiting a product decision")
    expect(described_class.actionable).to include(finding)
  end
end
