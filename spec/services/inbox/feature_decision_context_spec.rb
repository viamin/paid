# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-021
RSpec.describe Inbox::FeatureDecisionContext do
  it "projects one shared decision with its held tasks and current design revision" do
    feature_intent = create(:feature_intent, :confidence_driven)
    decision = create(:feature_intent_decision, feature_intent:, prompt: "Which analyzer evidence is sufficient?")
    first_issue = create(:issue, project: feature_intent.project, github_number: 41, title: "Collect native evidence")
    second_issue = create(:issue, project: feature_intent.project, github_number: 42, title: "Collect sidecar evidence")
    create(:feature_intent_issue, feature_intent:, issue: first_issue)
    create(:feature_intent_issue, feature_intent:, issue: second_issue)
    create(:feature_intent_design_pr, feature_intent:, pull_request_number: 73,
      head_sha: "current-design-revision", reviewed_head_sha: nil)

    context = described_class.call(feature_intent: feature_intent)

    expect(context.decisions).to contain_exactly(
      have_attributes(id: decision.id, prompt: "Which analyzer evidence is sufficient?", design_claim: decision.design_claim)
    )
    expect(context.tasks).to contain_exactly(
      have_attributes(number: 41, title: "Collect native evidence"),
      have_attributes(number: 42, title: "Collect sidecar evidence")
    )
    expect(context.design_revisions).to contain_exactly(
      have_attributes(number: 73, revision: "current-design-revision", state: "open")
    )
    expect(context.next_actions).to contain_exactly(have_attributes(kind: "answer_or_clarify"))
  end

  it "does not manufacture an approval action for confidence-driven planning" do
    feature_intent = create(:feature_intent, :confidence_driven)
    create(:feature_intent_decision, feature_intent:)

    context = described_class.call(feature_intent:)

    expect(context.next_actions.map(&:kind)).not_to include("approve")
  end
end
