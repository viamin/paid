# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::RouteDrift do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:brief_issue) { create(:issue, project:) }
  let(:feature_intent) { create(:feature_intent, project:) }
  let(:actor) { create(:user, account:) }

  before { create(:feature_intent_issue, feature_intent:, issue: brief_issue) }

  # Production shape: RecordRunDecisions groups a run's decisions into a
  # checkpoint bound to the design PR head and the brief issue's canonical
  # acceptance token, then RespondToDecision settles it.
  def settled_checkpoint!(design_revision:, acceptance_revision:)
    run = create(:agent_run, project:, issue: brief_issue, goal: "create_feature")
    question = create(:feature_intent_decision, feature_intent:, source_agent_run: run)
    checkpoint = ProjectDelegation::IntentCheckpoint::Plan.call(
      feature_intent:, questions: [ question ],
      recommendation: "Settle the material questions before approving the design.",
      alternatives: [], consequences: [ "Approval stays blocked until settled." ],
      affected_scope: { "design_claims" => [ question.design_claim ] },
      evidence: [ { "source" => "agent_run", "reference" => run.id.to_s } ],
      design_revision:, acceptance_revision:
    ).checkpoint
    ProjectDelegation::IntentCheckpoint::Settle.call(
      checkpoint:, actor:, answers: { question.id.to_s => "Proceed." }, design_revision:, acceptance_revision:
    )
    checkpoint
  end

  def acceptance_token(criteria)
    create(:agent_run, :completed, project:, issue: brief_issue, goal: "analyze_issue",
      reconciliation: { "assessment" => { "criteria" => criteria } })
    Automation::DelegatedActionAdmission.revision_tokens(issue: brief_issue)["acceptance_revision"]
  end

  it "routes one focused re-decision per settled checkpoint on a design change" do
    checkpoint = settled_checkpoint!(design_revision: "design-1", acceptance_revision: "acceptance-1")

    expect {
      described_class.on_design_change(feature_intent:, design_revision: "design-2")
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by(source: "project_delegation.intent_checkpoint")
    expect(notification.metadata["reasons"]).to eq("design_revision" => "design-2", "acceptance_revision" => "acceptance-1")
    expect(notification.metadata["authorization_id"]).to eq(checkpoint.id.to_s)
  end

  it "deduplicates a repeated design change for the same revision tuple" do
    settled_checkpoint!(design_revision: "design-1", acceptance_revision: "acceptance-1")

    described_class.on_design_change(feature_intent:, design_revision: "design-2")

    expect {
      described_class.on_design_change(feature_intent:, design_revision: "design-2")
    }.not_to change(Notification, :count)
  end

  it "does not re-prompt a checkpoint already bound to the design change's revision" do
    settled_checkpoint!(design_revision: "design-2", acceptance_revision: "acceptance-1")

    expect {
      described_class.on_design_change(feature_intent:, design_revision: "design-2")
    }.not_to change(Notification, :count)
  end

  it "routes a re-decision when re-recorded acceptance criteria drift from the settlement" do
    settled_token = acceptance_token([ { "criterion" => "Original scope", "state" => "satisfied" } ])
    settled_checkpoint!(design_revision: "design-1", acceptance_revision: settled_token)
    refreshed_token = acceptance_token([ { "criterion" => "Expanded scope", "state" => "satisfied" } ])

    expect {
      described_class.on_acceptance_change(issue: brief_issue)
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by(source: "project_delegation.intent_checkpoint")
    expect(notification.metadata["reasons"]).to eq("design_revision" => "design-1", "acceptance_revision" => refreshed_token)
  end

  it "does not re-prompt when the re-recorded acceptance criteria still match the settlement" do
    settled_token = acceptance_token([ { "criterion" => "Stable scope", "state" => "satisfied" } ])
    settled_checkpoint!(design_revision: "design-1", acceptance_revision: settled_token)
    acceptance_token([ { "criterion" => "Stable scope", "state" => "satisfied" } ])

    expect {
      described_class.on_acceptance_change(issue: brief_issue)
    }.not_to change(Notification, :count)
  end

  it "does not treat an implementation issue's audit as drift for the brief issue's binding" do
    settled_token = acceptance_token([ { "criterion" => "Original scope", "state" => "satisfied" } ])
    settled_checkpoint!(design_revision: "design-1", acceptance_revision: settled_token)
    implementation_issue = create(:issue, project:)
    create(:feature_intent_issue, feature_intent:, issue: implementation_issue)
    create(:agent_run, :completed, project:, issue: implementation_issue, goal: "analyze_issue",
      reconciliation: { "assessment" => { "criteria" => [ { "criterion" => "Unrelated", "state" => "satisfied" } ] } })

    expect {
      described_class.on_acceptance_change(issue: implementation_issue)
    }.not_to change(Notification, :count)
  end

  it "skips checkpoints that have no settlement yet" do
    run = create(:agent_run, project:, issue: brief_issue, goal: "create_feature")
    question = create(:feature_intent_decision, feature_intent:, source_agent_run: run)
    ProjectDelegation::IntentCheckpoint::Plan.call(
      feature_intent:, questions: [ question ],
      recommendation: "Settle the material questions before approving the design.",
      alternatives: [], consequences: [ "Approval stays blocked until settled." ],
      affected_scope: {}, evidence: [],
      design_revision: "design-1", acceptance_revision: "acceptance-1"
    )

    expect {
      described_class.on_design_change(feature_intent:, design_revision: "design-2")
    }.not_to change(Notification, :count)
  end
end
