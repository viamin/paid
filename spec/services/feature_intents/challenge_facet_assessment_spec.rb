# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-003 FACET-CONFIDENCE-005
RSpec.describe FeatureIntents::ChallengeFacetAssessment do
  let(:direction) { create(:feature_intent_facet_direction) }
  let(:facet) { direction.feature_intent_facet }
  let(:actor) { create(:user, account: facet.account) }
  let!(:superseded) do
    FeatureIntents::IngestFacetEvidence.call(facet:, attributes: {
      idempotency_key: "old", source_type: "human_statement", source_reference: "chat-old",
      statement: "Use mouse controls.", occurred_at: 1.hour.ago, actor: actor
    })
  end

  it "records a chat correction, supersedes the contradicted statement, and queues reassessment" do
    expect {
      result = described_class.call(facet:, actor:, statement: "Correction: keyboard controls are required.",
        source_reference: "chat-new", supersedes: superseded)
      expect(result.evidence).to have_attributes(source_type: "human_correction", source_reference: "chat-new")
      expect(result.assessment.status).to eq("pending")
    }.to have_enqueued_job(FeatureIntents::AssessFacetJob)

    expect(superseded.reload.superseded_by).to be_present
    expect(facet.reload.evidence_revision).to eq(2)
  end
end
