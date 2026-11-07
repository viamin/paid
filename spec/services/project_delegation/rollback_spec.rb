# frozen_string_literal: true

require "rails_helper"

# Conservative delegation rollback (RDR-080): selecting conservative blocks
# the next delegated boundary for in-flight work, preserves every
# authorization, evidence, and audit row, and routes one focused recovery
# decision per in-flight delegated authorization.
# @spec PROJECT-DELEGATION-006
RSpec.describe ProjectDelegation::Rollback do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, :with_github_installation, account:, created_by: owner) }
  let(:issue) { create(:issue, project: project) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    ProjectDelegation::Posture.select(project: project, user: owner, level: "bounded_delivery")

    assessment_run = create(:agent_run, :completed, project: project, issue: issue)
    assessment_run.update!(reconciliation: {
      "assessment" => PartialCloseouts::Assessment.snapshot(assessment_run, { "criteria" => [], "gaps" => [] })
    })
  end

  def authorize_delegated_review(work_item = issue)
    create(:bounded_delegated_action,
      project: project,
      issue: work_item,
      action: "review",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: work_item, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
  end

  def recheck(boundary: :dequeue)
    Automation::DelegatedActionAdmission.call(
      project: project, issue: issue, goal: "review", boundary: boundary
    )
  end

  it "permits the boundary before rollback for the delegated admission" do
    authorize_delegated_review

    expect(recheck).to be_permitted
  end

  it "selects conservative, blocks the next delegated boundary, and keeps every evidence row" do
    authorization = authorize_delegated_review
    evidence_before = authorization.evidence

    result = described_class.call(project: project, actor: owner, reason: "pilot reversal")

    expect(result.posture.reload).to have_attributes(level: "conservative", selected_by: owner)
    expect(result.posture.revision).to be > 1
    expect(authorization.reload.evidence).to eq(evidence_before)
    expect(authorization.reload).to be_active

    blocked = recheck
    expect(blocked).to be_blocked
    expect(blocked.reasons).to include(:posture_revision, :posture_delegation)
  end

  it "routes one focused recovery decision per in-flight delegated authorization" do
    authorization = authorize_delegated_review
    other_issue = create(:issue, project: project)
    other_assessment = create(:agent_run, :completed, project: project, issue: other_issue)
    other_assessment.update!(reconciliation: {
      "assessment" => PartialCloseouts::Assessment.snapshot(other_assessment, { "criteria" => [], "gaps" => [] })
    })
    other_authorization = authorize_delegated_review(other_issue)

    result = described_class.call(project: project, actor: owner, reason: "pilot reversal")

    expect(result.affected_authorizations.map(&:id)).to contain_exactly(authorization.id, other_authorization.id)
    notifications = Notification.where(source: described_class::NOTIFICATION_SOURCE)
    expect(notifications.count).to eq(2)
    recovery = notifications.find { |notification| notification.metadata["authorization_id"] == authorization.id }
    expect(recovery).to be_blocking
    expect(recovery.metadata).to include(
      "boundary" => "rollback",
      "reasons" => [ "posture_rollback" ]
    )
    expect(recovery.subject).to eq(issue)
  end

  it "is idempotent for already-recovered work and repeated rollbacks" do
    authorization = authorize_delegated_review

    described_class.call(project: project, actor: owner, reason: "first")
    described_class.call(project: project, actor: owner, reason: "second")

    notifications = Notification.where(source: described_class::NOTIFICATION_SOURCE, subject: issue)
    expect(notifications.count).to eq(1)
    expect(authorization.reload).to be_active
    expect(project.reload.project_delegation_posture.level).to eq("conservative")
  end

  it "skips authorizations that were never admitted under a delegating posture" do
    authorization = authorize_delegated_review
    authorization.update!(evidence: authorization.evidence.except("posture_level"))

    result = described_class.call(project: project, actor: owner, reason: "pilot reversal")

    expect(result.affected_authorizations).to be_empty
    expect(Notification.where(source: described_class::NOTIFICATION_SOURCE)).to be_empty
  end

  it "records the rollback audit events with the mutation and the affected count" do
    authorize_delegated_review

    described_class.call(project: project, actor: owner, reason: "pilot reversal")

    mutation = account.account_activity_events.by_action("project_delegation.rolled_back").last
    expect(mutation).to have_attributes(actor: owner, subject: project.project_delegation_posture)
    expect(mutation.metadata).to include("reason" => "pilot reversal", "from_level" => "bounded_delivery")
    completed = account.account_activity_events.by_action("project_delegation.rollback_completed").last
    expect(completed.metadata).to include("affected_authorizations" => 1)
  end

  it "creates the conservative posture record when none exists yet" do
    bare_project = create(:project, account: account, created_by: owner)
    FeatureFlags.enable!(:automation_phases, project: bare_project)
    FeatureFlags.enable!(:project_delegation, project: bare_project)

    result = described_class.call(project: bare_project, actor: owner, reason: "cold rollback")

    expect(result.posture.reload).to have_attributes(level: "conservative", revision: 1)
    expect(Notification.where(source: described_class::NOTIFICATION_SOURCE)).to be_empty
  end
end
