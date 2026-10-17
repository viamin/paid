# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-002
RSpec.describe FeatureIntentFacetEvidence do
  let(:facet) { create(:feature_intent_facet) }

  it "requires a decision from the facet feature" do
    decision = create(:feature_intent_decision, feature_intent: create(:feature_intent, project: facet.feature_intent.project))
    evidence = build_evidence(feature_intent_decision: decision)

    expect(evidence).to be_invalid
    expect(evidence.errors[:feature_intent_decision]).to include("must belong to the evidence facet feature")
  end

  it "requires superseding evidence from the same account and facet" do
    other_facet = create(:feature_intent_facet, feature_intent: facet.feature_intent)
    superseding_evidence = create_evidence(facet: other_facet, idempotency_key: "superseding-evidence")
    evidence = build_evidence(superseded_by: superseding_evidence)

    expect(evidence).to be_invalid
    expect(evidence.errors[:superseded_by]).to include("must belong to the evidence account and facet")
  end

  private

  def build_evidence(**attributes)
    described_class.new(evidence_attributes.merge(attributes))
  end

  def create_evidence(facet:, **attributes)
    described_class.create!(evidence_attributes.merge(attributes).merge(feature_intent_facet: facet, account: facet.account))
  end

  def evidence_attributes
    {
      account: facet.account,
      feature_intent_facet: facet,
      idempotency_key: "evidence-#{SecureRandom.uuid}",
      source_type: "human_statement",
      source_reference: "chat-message",
      statement: "Keep the keyboard workflow.",
      occurred_at: Time.current,
      evidence_revision: 1
    }
  end
end
