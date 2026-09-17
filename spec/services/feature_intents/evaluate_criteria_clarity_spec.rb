# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-006
RSpec.describe FeatureIntents::EvaluateCriteriaClarity do
  let(:feature_intent) { create(:feature_intent, criteria_clarity_state: "pending") }

  it "persists a clear verdict from the review" do
    allow(FeatureIntents::CriteriaClarityReview).to receive(:call)
      .and_return(FeatureIntents::CriteriaClarityReview::Result.new(clear: true, confidence: 0.9, explanation: "Specific and checkable."))

    described_class.call(feature_intent: feature_intent)

    expect(feature_intent.reload.criteria_clarity_state).to eq("clear")
    expect(feature_intent.criteria_clarity_explanation).to eq("Specific and checkable.")
    expect(feature_intent.criteria_clarity_evaluated_at).to be_present
  end

  it "persists a blank explanation when a clear verdict provides no explanation, rather than the failure-mode fallback" do
    allow(FeatureIntents::CriteriaClarityReview).to receive(:call)
      .and_return(FeatureIntents::CriteriaClarityReview::Result.new(clear: true, confidence: 0.9, explanation: ""))

    described_class.call(feature_intent: feature_intent)

    expect(feature_intent.reload.criteria_clarity_state).to eq("clear")
    expect(feature_intent.criteria_clarity_explanation).to eq("")
  end

  it "persists a vague verdict from the review" do
    allow(FeatureIntents::CriteriaClarityReview).to receive(:call)
      .and_return(FeatureIntents::CriteriaClarityReview::Result.new(clear: false, confidence: 0.9, explanation: "Too vague."))

    described_class.call(feature_intent: feature_intent)

    expect(feature_intent.reload.criteria_clarity_state).to eq("vague")
    expect(feature_intent.criteria_clarity_explanation).to eq("Too vague.")
  end

  it "fails closed to vague when the review itself fails" do
    allow(FeatureIntents::CriteriaClarityReview).to receive(:call).and_return(nil)

    described_class.call(feature_intent: feature_intent)

    expect(feature_intent.reload.criteria_clarity_state).to eq("vague")
    expect(feature_intent.criteria_clarity_explanation).to be_present
  end
end
