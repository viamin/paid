# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-002
RSpec.describe FeatureIntents::IngestFacetEvidence do
  let(:facet) { create(:feature_intent_facet) }
  let(:attributes) do
    {
      idempotency_key: "message-42",
      source_type: "human_statement",
      source_reference: "chat-message-42",
      statement: "Keep the keyboard workflow.",
      textual_context: "Response to the interaction question after the diagram was replaced.",
      occurred_at: Time.current
    }
  end

  it "records attribution and textual context without a diagram and advances evidence once" do
    evidence = described_class.call(facet:, attributes:)

    expect(evidence).to have_attributes(attributes.except(:occurred_at))
    expect(evidence.evidence_revision).to eq(1)
    expect(facet.reload.evidence_revision).to eq(1)
  end

  it "queues background reassessment for every active direction only once per new evidence item" do
    create(:feature_intent_facet_direction, feature_intent_facet: facet, name: "Primary")
    create(:feature_intent_facet_direction, feature_intent_facet: facet, name: "Alternative")

    expect { described_class.call(facet:, attributes:) }.to have_enqueued_job(FeatureIntents::AssessFacetJob).exactly(2).times
    expect { described_class.call(facet:, attributes:) }.not_to have_enqueued_job(FeatureIntents::AssessFacetJob)
  end

  it "is idempotent for repeated source ingestion" do
    first = described_class.call(facet:, attributes:)
    second = described_class.call(facet:, attributes:)

    expect(second).to eq(first)
    expect(facet.reload.evidence_revision).to eq(1)
  end

  it "rejects an idempotency key already used for another facet" do
    described_class.call(facet:, attributes:)
    other_facet = create(:feature_intent_facet, feature_intent: facet.feature_intent)

    expect { described_class.call(facet: other_facet, attributes:) }
      .to raise_error(described_class::IdempotencyConflict, "evidence key belongs to another facet")

    expect(other_facet.reload.evidence_revision).to eq(0)
  end
end
