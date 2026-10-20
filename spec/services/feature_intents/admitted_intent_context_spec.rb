# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-013 @spec FACET-CONFIDENCE-015
# @spec CONFIDENCE-DELIVERY-007 @spec CONFIDENCE-DELIVERY-010
RSpec.describe FeatureIntents::AdmittedIntentContext do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:feature) { create(:feature_intent, :confidence_driven, project: project) }

  before { create(:feature_intent_issue, feature_intent: feature, issue: issue) }

  it "snapshots scored evidence and keeps it unchanged after later evidence arrives" do
    facet = create(:feature_intent_facet, feature_intent: feature, issue: issue, evidence_revision: 1)
    direction = create(:feature_intent_facet_direction, feature_intent_facet: facet)
    create(:feature_intent_facet_assessment, status: "completed", feature_intent_facet_direction: direction,
      evidence_revision: 1, intent_score: 92, technical_score: 84,
      explanation: "The expressed direction fits the admitted scope.")
    FeatureIntentFacetEvidence.create!(account: project.account, feature_intent_facet: facet,
      feature_intent_facet_direction: direction, statement: "Keep keyboard navigation.",
      source_type: "human_statement", source_reference: "comment-1", idempotency_key: "evidence-1",
      occurred_at: Time.current, evidence_revision: 1)

    snapshot = described_class.capture(issue: issue)
    facet.update!(evidence_revision: 2)

    expect(snapshot.fetch("policy")).to eq("confidence_driven")
    expect(snapshot.dig("facets", 0, "intent_score")).to eq(92)
    expect(snapshot.dig("facets", 0, "technical_score")).to eq(84)
    expect(snapshot.dig("facets", 0, "expressed_intent")).to include("Keep keyboard navigation.")
    expect(snapshot.dig("facets", 0, "evidence_revision")).to eq(1)
  end
end
