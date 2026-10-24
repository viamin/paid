# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-019
RSpec.describe FeatureIntents::RespondToDecision do
  it "records an attributable response on the existing decision" do
    decision = create(:feature_intent_decision)
    actor = create(:user, account: decision.feature_intent.project.account)

    described_class.call(decision:, actor:, answer: "Use CSV exports only.")

    expect(decision.reload).to have_attributes(status: "resolved", answer: "Use CSV exports only.", resolved_by: actor)
  end

  it "rejects blank and repeated responses without changing the decision" do
    decision = create(:feature_intent_decision)
    actor = create(:user, account: decision.feature_intent.project.account)

    expect { described_class.call(decision:, actor:, answer: " ") }
      .to raise_error(described_class::InvalidResponseError)

    decision.resolve!(by: actor, answer: "Already answered.")
    expect { described_class.call(decision:, actor:, answer: "Again") }
      .to raise_error(described_class::StaleDecisionError)
  end

  it "rejects a response longer than the session-backed draft limit" do
    decision = create(:feature_intent_decision)
    actor = create(:user, account: decision.feature_intent.project.account)

    expect {
      described_class.call(decision:, actor:, answer: "a" * (FeatureIntents::ResponseDrafts::MAX_ANSWER_CHARS + 1))
    }.to raise_error(described_class::InvalidResponseError, "Responses must be #{FeatureIntents::ResponseDrafts::MAX_ANSWER_CHARS} characters or fewer.")

    expect(decision.reload).to have_attributes(status: "open", answer: nil)
  end
end
