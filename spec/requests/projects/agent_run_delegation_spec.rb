# frozen_string_literal: true

require "rails_helper"

# RDR-080 surface parity: the agent-run detail reads delegated authority from
# the shared ProjectDelegation::Projection instead of inferring it from run or
# queue state.
#
# @spec PROJECT-DELEGATION-005
RSpec.describe "Project agent run delegated authority" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }
  let!(:agent_run) { create(:agent_run, project:, issue:, goal: "create_pr") }

  before { sign_in user }

  def authorize_review
    create(:bounded_delegated_action,
      project: project,
      issue: issue,
      action: "review",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: issue, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
  end

  it "renders no delegated-authority surface while the project gate is off" do # @spec PROJECT-DELEGATION-005
    authorize_review

    get project_agent_run_path(project, agent_run)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Delegated authority")
  end

  it "renders the governing authorization's effective authority from the projection" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:project_delegation, project:)
    authorize_review

    get project_agent_run_path(project, agent_run)

    expect(response.body).to include("Delegated authority")
    expect(response.body).to include("legacy policy")
    expect(response.body).not_to include("project phase defaults")
  end

  it "shows the shared-contract authority when the phase model governs" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:project_delegation, project:)
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => true },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
    authorize_review

    get project_agent_run_path(project, agent_run)

    expect(response.body).to include("Delegated authority")
    expect(response.body).to include("project phase defaults")
  end

  it "omits the section when the run's work item has no bounded authorization" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:project_delegation, project:)

    get project_agent_run_path(project, agent_run)

    expect(response.body).not_to include("Delegated authority")
  end
end
