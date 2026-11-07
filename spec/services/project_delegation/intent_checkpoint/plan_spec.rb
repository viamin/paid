# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::Plan do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project) }

  describe "grouping material feature decisions" do
    it "groups open decisions under their recorded design claim with recommendation and consequences" do
      feature = create(:feature_intent, project: project, approved_design_revision: "abc123design")
      create(:feature_intent_issue, feature_intent: feature, issue: issue)
      create(:feature_intent_decision, :inferred_decision, feature_intent: feature,
        design_claim: "Ingest keeps a rolling window.", source_agent_run: nil)

      result = described_class.call(project: project, issue: issue)

      expect(result.groups).to contain_exactly(
        have_attributes(
          key: start_with("claim:"),
          question: "[inferred] Assuming X applies to new records only.",
          recommendation: "[inferred] Assuming X applies to new records only.",
          consequences: described_class::DECISION_CONSEQUENCES,
          affected_scope: "Ingest keeps a rolling window.",
          source: start_with("feature_intent_decision:")
        )
      )
    end

    it "keeps resolved decisions out of the checkpoint" do
      feature = create(:feature_intent, project: project)
      create(:feature_intent_issue, feature_intent: feature, issue: issue)
      create(:feature_intent_decision, :resolved, feature_intent: feature)

      expect(described_class.call(project: project, issue: issue).groups).to be_empty
    end

    it "groups decisions that share a design claim under one key" do
      feature = create(:feature_intent, project: project)
      create(:feature_intent_issue, feature_intent: feature, issue: issue)
      create(:feature_intent_decision, feature_intent: feature, design_claim: "Same claim.", prompt: "First question?")
      create(:feature_intent_decision, feature_intent: feature, design_claim: "Same claim.", prompt: "Second question?")

      result = described_class.call(project: project, issue: issue)
      keys = result.groups.map(&:key)

      expect(keys).to contain_exactly(keys.first, keys.first)
    end
  end

  describe "presenting persisted clarifying questions" do
    it "shows recommendation, alternatives, consequences, scope, and evidence" do
      issue.update!(needs_input_questions: structured_window_question)

      result = described_class.call(project: project, issue: issue)

      expect(result.groups).to contain_exactly(
        have_attributes(
          key: start_with("clarifying:"),
          question: "How many days should the ingest window cover?",
          recommendation: "7 days",
          alternatives: contain_exactly("7 days", "30 days"),
          consequences: "The retention policy only promises a week.",
          affected_scope: issue.title,
          evidence: [ "app/models/ingest.rb" ],
          source: "needs_input_questions"
        )
      )
    end

    it "keeps legacy string questions reviewable without inventing a recommendation" do
      issue.update!(needs_input_questions: [ "What should the default window be?" ])

      group = described_class.call(project: project, issue: issue).groups.first

      expect(group.question).to eq("What should the default window be?")
      expect(group.recommendation).to be_nil
    end

    def structured_window_question
      [ {
        "question" => "How many days should the ingest window cover?",
        "choices" => [
          { "label" => "7 days", "detail" => "One week of history" },
          { "label" => "30 days", "detail" => "One month of history" }
        ],
        "choice_type" => "single",
        "recommendation" => "7 days",
        "rationale" => "The retention policy only promises a week.",
        "evidence_references" => [ "app/models/ingest.rb" ]
      } ]
    end
  end

  describe "revision binding tokens" do
    it "binds to the feature's approved design revision when a feature owns the issue" do
      feature = create(:feature_intent, project: project, approved_design_revision: "abc123design")
      create(:feature_intent_issue, feature_intent: feature, issue: issue)

      revisions = ProjectDelegation::IntentCheckpoint::Revisions.for(issue)

      expect(revisions.fetch("design_revision")).to eq("abc123design")
    end

    it "falls back to the work item intent digest and reuses the admission acceptance token" do
      revisions = ProjectDelegation::IntentCheckpoint::Revisions.for(issue)
      tokens = Automation::DelegatedActionAdmission.revision_tokens(issue: issue)

      expect(revisions.fetch("design_revision")).to eq(tokens.fetch("intent_revision"))
      expect(revisions.fetch("acceptance_revision")).to eq(tokens.fetch("acceptance_revision"))
    end
  end

  describe "question set identity" do
    it "is stable for whitespace-only edits and changes for a different question" do
      issue.update!(needs_input_questions: [ "What should the  default window be?" ])
      first = described_class.call(project: project, issue: issue)

      issue.update!(needs_input_questions: [ "What should the default window  be?" ])
      expect(described_class.call(project: project, issue: issue).question_set_digest).to eq(first.question_set_digest)

      issue.update!(needs_input_questions: [ "How large may the window grow?" ])
      expect(described_class.call(project: project, issue: issue).question_set_digest).not_to eq(first.question_set_digest)
    end
  end
end
