# frozen_string_literal: true

require "rails_helper"

# The explicit delegation hold (RDR-080): an authorized actor pauses delegated
# work for a project without changing the posture, the admission snapshots, or
# the delegated evidence, and releases it explicitly afterwards.
#
# @spec PROJECT-DELEGATION-010
RSpec.describe ProjectDelegation::PlaceHold do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:project) { create(:project, :with_github_installation, account: account, created_by: owner) }
  let(:issue) { create(:issue, project:) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    create(:project_delegation_posture, project:, level: "bounded_delivery", revision: 1, selected_by: owner)
    assessment_run = create(:agent_run, :completed, project:, issue:)
    assessment_run.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(
      assessment_run, { "criteria" => [], "gaps" => [] }
    ) })
  end

  def authorize(work_item: issue, action: "review")
    create(:bounded_delegated_action,
      project:,
      issue: work_item,
      action: action,
      created_by: owner,
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item:, action:, acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
  end

  def place(actor: owner, reason: "Waiting for the security review")
    described_class.call(project:, actor:, reason:)
  end

  it "records a durable hold with its actor and reason" do
    hold = place

    expect(hold).to have_attributes(status: "held", reason: "Waiting for the security review", held_by: owner)
    expect(hold.account).to eq(account)
    expect(hold.project).to eq(project)
  end

  it "records the hold in the immutable audit history" do
    hold = place

    event = AccountActivityEvent.where(action: "project_delegation.hold_placed").last
    expect(event).to have_attributes(actor: owner, subject: hold)
    expect(event.metadata).to include("project_id" => project.id, "reason" => "Waiting for the security review")
  end

  it "prevents the next delegated action" do
    authorize

    place

    result = Automation::DelegatedActionAdmission.call(project:, issue:, goal: "review", boundary: :dequeue)

    expect(result).to be_blocked
    expect(result.reasons).to include(:delegation_hold)
    expect(result.recovery).to eq("release_hold")
  end

  it "routes the in-flight delegated work to one focused decision" do
    authorization = authorize

    place

    notification = Notification.find_by(source: ProjectDelegation::RouteAffectedWork::SOURCE)
    expect(notification.subject).to eq(issue)
    expect(notification.metadata).to include(
      "authorization_id" => authorization.id,
      "reasons" => [ "delegation_hold" ],
      "recovery" => "release_hold"
    )
  end

  it "keeps the posture, the admission snapshot, and the delegated evidence" do
    authorization = authorize

    place

    expect(project.delegation_posture.reload.level).to eq("bounded_delivery")
    expect(authorization.reload.evidence).to include("posture_snapshot" => hash_including("revision" => 1))
    expect(authorization.reload.status).to eq("active")
  end

  it "refuses an actor who may not own the delegation posture" do
    expect { place(actor: member) }.to raise_error(described_class::PermissionDenied)
    expect(ProjectDelegationHold.count).to eq(0)
  end

  it "refuses a hold without a reason" do
    expect { place(reason: "  ") }.to raise_error(described_class::MissingReason)
    expect(ProjectDelegationHold.count).to eq(0)
  end

  it "refuses a second hold for the same project" do
    place

    expect { place }.to raise_error(described_class::AlreadyHeld)
    expect(ProjectDelegationHold.count).to eq(1)
  end
end
