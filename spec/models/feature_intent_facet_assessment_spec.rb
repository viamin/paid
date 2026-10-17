# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-001
RSpec.describe FeatureIntentFacetAssessment do
  subject(:assessment) do
    build(:feature_intent_facet_assessment, status:, intent_score:, technical_score:)
  end

  let(:status) { "unknown" }
  let(:intent_score) { nil }
  let(:technical_score) { nil }

  it "preserves unknown independently from rejection or approval" do
    expect(assessment).to be_valid
    expect(assessment.intent_score).to be_nil
    expect(assessment.technical_score).to be_nil
  end

  context "when completed" do
    let(:status) { "completed" }

    it "requires independently bounded scores" do
      assessment.intent_score = 101
      assessment.technical_score = 80

      expect(assessment).not_to be_valid
      expect(assessment.errors[:intent_score]).to be_present
    end

    it "does not accept a completed assessment with an unknown axis" do
      assessment.technical_score = nil

      expect(assessment).not_to be_valid
      expect(assessment.errors[:base]).to include("completed assessments require both scores")
    end
  end
end
