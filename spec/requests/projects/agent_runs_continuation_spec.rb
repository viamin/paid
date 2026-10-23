# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-004 @spec AUTOMATION-PHASES-005 @spec AUTOMATION-PHASES-009
# @spec AUTOMATION-PHASES-010 @spec AUTOMATION-PHASES-011
RSpec.describe "Project agent run continuation" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }

  before do
    sign_in user
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => false, "merge" => false },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  it "creates a run and continuation grant from the rendered form signature" do
    get new_project_agent_run_path(project, goal: "create_pr")
    signature = rendered_signature

    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_pr",
        issue_id: issue.id,
        continuation_authorized: "1",
        continuation_endpoint: "merge",
        continuation_notice_signature: signature
      }
    }.to change(AgentRun, :count).by(1)
      .and change(WorkItemContinuationGrant, :count).by(1)

    expect(response).to redirect_to(project_path(project))
    expect(WorkItemContinuationGrant.last).to have_attributes(
      issue:, start_phase: "coding", endpoint: "merge", created_by: user
    )
  end

  it "returns an invalid endpoint to the form without creating a run" do
    get new_project_agent_run_path(project, goal: "create_pr")
    signature = rendered_signature

    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_pr",
        issue_id: issue.id,
        continuation_authorized: "1",
        continuation_endpoint: "issue_preparation",
        continuation_notice_signature: signature
      }
    }.not_to change(AgentRun, :count)

    expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
    expect(flash[:alert]).to eq("Choose a continuation endpoint offered for this action.")
  end

  it "returns unauthorized merge delegation to the form without creating a run" do
    member = create(:user, :member, account:)
    sign_in member
    get new_project_agent_run_path(project, goal: "create_pr")
    signature = rendered_signature

    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_pr",
        issue_id: issue.id,
        continuation_authorized: "1",
        continuation_endpoint: "merge",
        continuation_notice_signature: signature
      }
    }.not_to change(AgentRun, :count)

    expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
    expect(flash[:alert]).to eq("You do not have permission to delegate merging for this project.")
  end

  it "returns a changed project policy to the form for review" do
    get new_project_agent_run_path(project, goal: "create_pr")
    signature = rendered_signature
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => false, "merge" => true },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )

    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_pr",
        issue_id: issue.id,
        continuation_notice_signature: signature
      }
    }.not_to change(AgentRun, :count)

    expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
    expect(flash[:alert]).to include("automation settings changed")
  end

  def rendered_signature
    Nokogiri::HTML(response.body)
      .at_css("input[name='continuation_notice_signature']")["value"]
  end
end
