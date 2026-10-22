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

  it "records the same chat correction against multiple facets without colliding on the idempotency key" do
    other_facet = create(:feature_intent_facet, feature_intent: facet.feature_intent, account: facet.account)
    create(:feature_intent_facet_direction, feature_intent_facet: other_facet)
    source_reference = "chat-message:same-message"

    first = described_class.call(facet:, actor:, statement: "Correction", source_reference:)
    second = described_class.call(facet: other_facet, actor:, statement: "Correction", source_reference:)

    expect(first.evidence.feature_intent_facet_id).to eq(facet.id)
    expect(second.evidence.feature_intent_facet_id).to eq(other_facet.id)
    expect(second.evidence).not_to eq(first.evidence)
  end

  it "returns a freshly scheduled assessment when the prior pending one already completed" do
    source_reference = "chat-message:replay"

    first = described_class.call(facet:, actor:, statement: "Correction", source_reference:)
    direction.assessments.update_all(status: "completed")

    second = nil
    expect { second = described_class.call(facet:, actor:, statement: "Correction", source_reference:) }
      .to have_enqueued_job(FeatureIntents::AssessFacetJob)

    expect(second.assessment).to be_persisted
    expect(second.assessment.status).to eq("pending")
    expect(second.evidence.id).to eq(first.evidence.id)
  end

  it "selects the active direction deterministically when more than one is active" do
    second_direction = create(:feature_intent_facet_direction, feature_intent_facet: facet,
      account: facet.account)
    direction.update!(created_at: 2.days.ago)
    second_direction.update!(created_at: 1.day.ago)

    result = described_class.call(facet:, actor:, statement: "Correction", source_reference: "chat-message:deterministic")

    expect(result.assessment.feature_intent_facet_direction_id).to eq(direction.id)
  end
end
