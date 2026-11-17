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
      design_revision: feature_intent.approved_design_revision,
      acceptance_revision: checkpoint.proposed_acceptance_revision
    )
  end

  it "binds a final response to revisions that changed while its checkpoint was open" do # @spec PROJECT-DELEGATION-002
    feature_intent = create(:feature_intent, approved_design_revision: "design-1")
    issue = create(:issue, project: feature_intent.project)
    run = create(:agent_run, project: feature_intent.project, issue:, goal: "create_feature")
    decision = create(:feature_intent_decision, feature_intent:, source_agent_run: run)
    checkpoint = create(:project_delegation_intent_checkpoint, feature_intent:,
      proposed_design_revision: "design-1", proposed_acceptance_revision: "acceptance-1")
    checkpoint.questions = [ decision ]
    actor = create(:user, account: feature_intent.project.account)

    feature_intent.update!(approved_design_revision: "design-2")
    create(:agent_run, :completed, project: feature_intent.project, issue:, goal: "analyze_issue",
      reconciliation: { "assessment" => { "criteria" => [ { "criterion" => "Expanded scope", "state" => "satisfied" } ] } })
    current_acceptance_revision = Automation::DelegatedActionAdmission.revision_tokens(issue:)["acceptance_revision"]

    described_class.call(decision:, actor:, answer: "Approve the expanded scope.")

    expect(checkpoint.reload.settlements.sole).to have_attributes(
      design_revision: "design-2", acceptance_revision: current_acceptance_revision
    )
  end

  it "keeps each question's own responder when different humans answer one checkpoint" do # @spec PROJECT-DELEGATION-002
    feature_intent = create(:feature_intent)
    first = create(:feature_intent_decision, feature_intent:)
    second = create(:feature_intent_decision, feature_intent:)
    checkpoint = create(:project_delegation_intent_checkpoint, feature_intent:)
    checkpoint.questions = [ first, second ]
    first_actor = create(:user, account: feature_intent.project.account)
    second_actor = create(:user, account: feature_intent.project.account)
    first_answered_at = 3.hours.ago.change(usec: 0)

    travel_to(first_answered_at) { described_class.call(decision: first, actor: first_actor, answer: "CSV exports only.") }
    described_class.call(decision: second, actor: second_actor, answer: "Narrow rollout.")

    expect(checkpoint.reload).to be_settled
    expect(first.reload).to have_attributes(resolved_by: first_actor, resolved_at: first_answered_at)
    expect(second.reload).to have_attributes(resolved_by: second_actor)
    expect(checkpoint.settlements.first.settled_by).to eq(second_actor)
    expect(checkpoint.settlements.first.answers.values).to contain_exactly("CSV exports only.", "Narrow rollout.")
  end
end
