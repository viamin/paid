# frozen_string_literal: true

require "rails_helper"

# The settings-surface half of the delegation posture: the automation-phases
# page shows the effective posture, its source and revision, the enabled
# action classes, reachable phases, applicable stop boundaries, and the
# reviews that remain human decisions, and an
# authorized owner or project admin selects the posture through the guarded
# write path.
# @spec PROJECT-DELEGATION-001
RSpec.describe "Project delegation posture settings" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }

  before do
    sign_in owner
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  def select_posture(level)
    patch project_delegation_posture_path(project), params: {
      project_delegation_posture: { level: level }
    }
  end

  it "shows the effective default posture and the reviews that stay human" do
    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Delegation posture")
    expect(response.body).to include("conservative")
    expect(response.body).to include("Effective posture")
    expect(response.body).to include("Remaining human reviews")
    expect(response.body).to include("Reachable phases")
    expect(response.body).to include("Applicable stop boundaries")
    expect(response.body).to include("Coding")
    expect(response.body).to include("Before Merge")
    expect(response.body).to include("Before Release &amp; Deployment")
  end

  it "selects bounded_delivery for an owner through the guarded write path" do
    select_posture("bounded_delivery")

    expect(response).to redirect_to(project_automation_phases_path(project))
    expect(project.delegation_posture.reload).to have_attributes(
      level: "bounded_delivery", revision: 1, selected_by: owner
    )
    expect(AccountActivityEvent.where(action: "project_delegation.posture_selected", subject: project)).to exist

    get project_automation_phases_path(project)
    expect(response.body).to include("bounded_delivery")
  end

  it "refuses a plain member and records nothing" do
    member = create(:user, :member, account: account)
    sign_in member

    select_posture("bounded_delivery")

    expect(response).to redirect_to(root_path)
    expect(project.delegation_posture).to be_nil
  end

  it "explains when a guard blocks broadening" do
    FeatureFlags.disable!(:automation_phases, project:)

    select_posture("bounded_delivery")

    expect(response).to redirect_to(project_automation_phases_path(project))
    follow_redirect!
    expect(response.body).to include("Delegation is not enabled for this project")
    expect(project.delegation_posture).to be_nil
  end

  it "explains when expansion evidence pauses a selected posture" do # @spec PROJECT-DELEGATION-001 PROJECT-DELEGATION-007
    create(:project_delegation_posture, project:, level: "bounded_delivery", selected_by: owner)
    FeatureFlags.enable!(:project_delegation_expansion, project:)

    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Expansion is paused")
    expect(response.body).to include("select the posture again")
  end

  it "keeps narrowing to conservative available as the rollback path" do
    create(:project_delegation_posture, project: project, level: "bounded_delivery", revision: 1,
      selected_by: owner)
    FeatureFlags.disable!(:automation_phases, project:)

    select_posture("conservative")

    expect(project.delegation_posture.reload).to have_attributes(level: "conservative", revision: 2)
  end

  it "hides the posture selection until the project opts in" do
    FeatureFlags.disable!(:project_delegation, project:)

    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Delegation posture")
  end

  it "holds delegated work and shows the hold on the settings surface" do # @spec PROJECT-DELEGATION-010
    post project_delegation_hold_path(project), params: {
      project_delegation_hold: { reason: "Waiting for the security review" }
    }

    expect(response).to redirect_to(project_automation_phases_path(project))
    hold = ProjectDelegationHold.held.find_by(project:)
    expect(hold).to have_attributes(reason: "Waiting for the security review", held_by: owner)

    get project_automation_phases_path(project)
    expect(response.body).to include("Delegated work is on hold")
    expect(response.body).to include("Waiting for the security review")
  end

  it "refuses a hold without a reason and records nothing" do # @spec PROJECT-DELEGATION-010
    post project_delegation_hold_path(project), params: {
      project_delegation_hold: { reason: "  " }
    }

    expect(response).to redirect_to(project_automation_phases_path(project))
    follow_redirect!
    expect(response.body).to include("A hold needs a reason")
    expect(ProjectDelegationHold.count).to eq(0)
  end

  it "refuses a plain member a hold" do # @spec PROJECT-DELEGATION-010
    sign_in create(:user, :member, account: account)

    post project_delegation_hold_path(project), params: {
      project_delegation_hold: { reason: "Waiting for the security review" }
    }

    expect(response).to redirect_to(root_path)
    expect(ProjectDelegationHold.count).to eq(0)
  end

  it "releases a hold through the guarded write path" do # @spec PROJECT-DELEGATION-010
    ProjectDelegation::PlaceHold.call(project:, actor: owner, reason: "Waiting for the security review")

    delete project_delegation_hold_path(project)

    expect(response).to redirect_to(project_automation_phases_path(project))
    expect(ProjectDelegationHold.held.where(project:)).to be_empty
    expect(AccountActivityEvent.where(action: "project_delegation.hold_released")).to exist
  end
end
