# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-006 @spec FEATURE-APPROVAL-007
RSpec.describe FeatureIntentDecision do
  it "requires the design claim it affects" do
    decision = build(:feature_intent_decision, design_claim: nil)

    expect(decision).not_to be_valid
    expect(decision.errors[:design_claim]).to be_present
  end

  it "requires a known kind" do
    decision = build(:feature_intent_decision, kind: "opinion")

    expect(decision).not_to be_valid
  end

  describe "#resolve!" do
    it "records the answer, resolver, and timestamp and marks it resolved" do
      decision = create(:feature_intent_decision)
      resolver = create(:user)

      decision.resolve!(by: resolver, answer: "New records only.")

      expect(decision.status).to eq("resolved")
      expect(decision.answer).to eq("New records only.")
      expect(decision.resolved_by).to eq(resolver)
      expect(decision.resolved_at).to be_present
    end

    it "enqueues a criteria-clarity re-evaluation for the feature intent" do
      decision = create(:feature_intent_decision)
      resolver = create(:user)

      expect { decision.resolve!(by: resolver, answer: "Yes.") }
        .to have_enqueued_job(FeatureIntents::EvaluateCriteriaClarityJob)
        .with(feature_intent_id: decision.feature_intent_id)
    end
  end

  describe "scopes" do
    it "separates open questions from inferred decisions" do
      question = create(:feature_intent_decision, kind: "question")
      inferred = create(:feature_intent_decision, :inferred_decision)
      create(:feature_intent_decision, :resolved, kind: "question")

      expect(described_class.questions.open_decisions).to contain_exactly(question)
      expect(described_class.inferred_decisions.open_decisions).to contain_exactly(inferred)
    end
  end
end
