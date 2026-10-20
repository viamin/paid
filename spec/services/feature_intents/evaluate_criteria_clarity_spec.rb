# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-011
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

  describe "lifecycle transitions (FEATURE-APPROVAL-019)" do
    def clear_review
      FeatureIntents::CriteriaClarityReview::Result.new(clear: true, confidence: 0.9, explanation: "Specific and checkable.")
    end

    def vague_review
      FeatureIntents::CriteriaClarityReview::Result.new(clear: false, confidence: 0.9, explanation: "Too vague.")
    end

    it "moves a clear-verdict feature with every decision resolved to ready_for_approval" do
      allow(FeatureIntents::CriteriaClarityReview).to receive(:call).and_return(clear_review)
      feature_intent.update!(status: "needs_decision")

      described_class.call(feature_intent: feature_intent)

      expect(feature_intent.reload.status).to eq("ready_for_approval")
    end

    it "moves a design_open feature to ready_for_approval when clarity is clear with no open decisions" do
      allow(FeatureIntents::CriteriaClarityReview).to receive(:call).and_return(clear_review)
      feature_intent.update!(status: "design_open")

      described_class.call(feature_intent: feature_intent)

      expect(feature_intent.reload.status).to eq("ready_for_approval")
    end

    it "holds the feature at needs_decision while an open question remains despite a clear verdict" do
      allow(FeatureIntents::CriteriaClarityReview).to receive(:call).and_return(clear_review)
      feature_intent.update!(status: "needs_decision")
      create(:feature_intent_decision, feature_intent: feature_intent, kind: "question")

      described_class.call(feature_intent: feature_intent)

      expect(feature_intent.reload.status).to eq("needs_decision")
    end

    it "moves a ready_for_approval feature back to needs_decision when a new open decision exists" do
      allow(FeatureIntents::CriteriaClarityReview).to receive(:call).and_return(clear_review)
      feature_intent.update!(status: "ready_for_approval")
      create(:feature_intent_decision, feature_intent: feature_intent, kind: "inferred_decision")

      described_class.call(feature_intent: feature_intent)

      expect(feature_intent.reload.status).to eq("needs_decision")
    end

    it "leaves the status alone on a vague verdict with no open decisions" do
      allow(FeatureIntents::CriteriaClarityReview).to receive(:call).and_return(vague_review)
      feature_intent.update!(status: "design_open")

      described_class.call(feature_intent: feature_intent)

      expect(feature_intent.reload.status).to eq("design_open")
    end

    it "never transitions a discovering, approved, or terminal feature" do
      allow(FeatureIntents::CriteriaClarityReview).to receive(:call).and_return(clear_review)

      %w[discovering approved_waiting_for_merge released revising cancelled].each do |status|
        feature_intent.update!(status: status)

        described_class.call(feature_intent: feature_intent)

        expect(feature_intent.reload.status).to eq(status)
      end
    end
  end
end
