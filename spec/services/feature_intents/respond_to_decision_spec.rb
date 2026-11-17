# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-019
RSpec.describe FeatureIntents::RespondToDecision do
  it "records an attributable response on the existing decision" do # @spec PROJECT-DELEGATION-007
    decision = create(:feature_intent_decision)
    actor = create(:user, account: decision.feature_intent.project.account)
    FeatureFlags.enable!(:project_delegation, project: decision.feature_intent.project)

    described_class.call(decision:, actor:, answer: "Use CSV exports only.")

    expect(decision.reload).to have_attributes(status: "resolved", answer: "Use CSV exports only.", resolved_by: actor)
    expect(InboxHistoryEvent.find_by(source: "project_delegation_pilot", result: "human_decision"))
      .to have_attributes(project: decision.feature_intent.project)
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

  it "settles a grouped checkpoint after its final human answer" do # @spec PROJECT-DELEGATION-002
    feature_intent = create(:feature_intent)
    first = create(:feature_intent_decision, feature_intent:)
    second = create(:feature_intent_decision, feature_intent:)
    checkpoint = create(:project_delegation_intent_checkpoint, feature_intent:)
    checkpoint.questions = [ first, second ]
    actor = create(:user, account: feature_intent.project.account)

    described_class.call(decision: first, actor:, answer: "Narrow rollout.")
    expect(checkpoint.reload.status).to eq("open")

    described_class.call(decision: second, actor:, answer: "Existing records only.")

    expect(checkpoint.reload).to be_settled
    expect(checkpoint.settlements).to have_attributes(size: 1)
    expect(checkpoint.settlements.first).to have_attributes(
      design_revision: checkpoint.proposed_design_revision,
      acceptance_revision: checkpoint.proposed_acceptance_revision
    )
  end
end
