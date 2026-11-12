# frozen_string_literal: true

require "rails_helper"

# Releasing an explicit delegation hold (RDR-080): the release is an ownership
# act, it keeps the released record and its audit history, and the delegated
# work continues only when every other boundary fact is still current.
#
# @spec PROJECT-DELEGATION-010
RSpec.describe ProjectDelegation::ReleaseHold do
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

  def authorize
    create(:bounded_delegated_action,
      project:,
      issue:,
      action: "review",
      created_by: owner,
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: issue, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
  end

  it "releases the hold and lets the delegated work continue" do
    authorize
    hold = ProjectDelegation::PlaceHold.call(project:, actor: owner, reason: "Waiting for the security review")

    expect(described_class.call(project:, actor: owner)).to be(true)

    expect(hold.reload).to have_attributes(status: "released", released_by: owner)
    expect(hold.released_at).to be_present
    expect(Automation::DelegatedActionAdmission.call(project:, issue:, goal: "review", boundary: :dequeue))
      .to be_permitted
  end

  it "records the release in the immutable audit history" do
    hold = ProjectDelegation::PlaceHold.call(project:, actor: owner, reason: "Waiting for the security review")

    described_class.call(project:, actor: owner)

    event = AccountActivityEvent.where(action: "project_delegation.hold_released").last
    expect(event).to have_attributes(actor: owner, subject: hold)
  end

  it "refuses an actor who may not own the delegation posture" do
    ProjectDelegation::PlaceHold.call(project:, actor: owner, reason: "Waiting for the security review")

    expect { described_class.call(project:, actor: member) }.to raise_error(described_class::PermissionDenied)
    expect(ProjectDelegationHold.held.count).to eq(1)
  end

  it "refuses to release a hold that does not exist" do
    expect { described_class.call(project:, actor: owner) }.to raise_error(described_class::NotHeld)
  end
end
