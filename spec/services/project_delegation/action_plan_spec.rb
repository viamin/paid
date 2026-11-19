# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-003
RSpec.describe ProjectDelegation::ActionPlan do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, :with_github_installation, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }
  let(:lineage) { Automation::DelegatedActionAdmission.lineage_issue_ids(issue) }
  let(:common) do
    {
      "intent_revision" => "intent-1", "acceptance_revision" => "acceptance-1",
      "evidence_revision" => "evidence-1", "policy_signature" => project.delegation_posture.policy_signature, "lineage" => lineage
    }
  end

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    create(:project_delegation_posture, project:, level: "bounded_delivery", selected_by: user)
  end

  it "requires action-specific evidence and records an auditable permit" do
    result = described_class.call(project:, work_item: issue, actor: user,
      action: "bounded_implementation_choice", evidence: common.merge(
        "alternatives" => [ "a", "b" ], "selected_option" => "a", "rationale" => "fits the settled design",
        "tests" => [ "spec" ], "review_evidence" => [ "review-1" ]
      ))

    expect(result).to be_permitted
    expect(result.audit_event).to have_attributes(action: "project_delegation.action_evaluated", actor: user)
    expect(result.audit_event.metadata).to include(
      "action" => "bounded_implementation_choice", "result" => "permitted", "work_item_id" => issue.id
    )
  end

  it "blocks reserved product and release decisions and records the routed decision" do
    result = described_class.call(project:, work_item: issue, actor: user,
      action: "release", evidence: common)

    expect(result).to be_blocked
    expect(result.reasons).to include("reserved_action")
    expect(result.audit_event.metadata).to include(
      "result" => "focused_decision_required", "routed_decision" => { "kind" => "focused_decision", "required" => true }
    )
  end

  it "blocks scope expansion, holds, and a new lineage" do
    result = described_class.call(project:, work_item: issue, actor: user,
      action: "technical_stop_recovery", evidence: common.merge(
        "failure_classification" => "timeout", "attempted_recovery" => "retry",
        "current_checks" => [ "ci" ], "budget_evidence" => "within-budget",
        "scope" => "new requirement", "explicit_hold" => true, "lineage" => [ issue.id + 1 ]
      ))

    expect(result).to be_blocked
    expect(result.reasons).to include("prohibited_scope", "lineage_changed", "explicit_hold")
  end

  it "allows follow-up recording only when it is explicitly non-executing" do
    result = described_class.call(project:, work_item: issue, actor: user,
      action: "focused_followup_ownership", evidence: common.merge(
        "finding" => "missing check", "affected_scope" => "same PR", "evidence" => [ "check-1" ],
        "owner" => user.id, "completion_dependency" => "follow-up admission", "follow_up_link" => "issue:2",
        "execute_follow_up" => false
      ))

    expect(result).to be_permitted
  end

  it "blocks a follow-up that would execute under the delegated authority" do
    result = described_class.call(project:, work_item: issue, actor: user,
      action: "focused_followup_ownership", evidence: common.merge(
        "finding" => "missing check", "affected_scope" => "same PR", "evidence" => [ "check-1" ],
        "owner" => user.id, "completion_dependency" => "follow-up admission", "follow_up_link" => "issue:2",
        "execute_follow_up" => true
      ))

    expect(result).to be_blocked
    expect(result.reasons).to include("follow_up_execution_prohibited")
  end

  it "accepts an evidenced closeout with no dependencies or open follow-ups" do
    result = described_class.call(project:, work_item: issue, actor: user,
      action: "evidence_gated_issue_closure", evidence: common.merge(
        "required_checks" => [ "ci" ], "review_merge_state" => "mergeable",
        "dependencies" => [], "open_followups" => []
      ))

    expect(result).to be_permitted
  end
end
