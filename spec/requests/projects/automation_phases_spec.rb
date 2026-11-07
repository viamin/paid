# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-008
# @spec AUTOMATION-PHASES-015 @spec AUTOMATION-PHASES-016
RSpec.describe "Project automation phases" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  before { sign_in user }

  it "renders the settings page" do
    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Automation phases")
  end

  it "updates the phase controls posted by the settings form" do
    patch project_automation_phases_path(project), params: {
      project: { phases: { "discovery" => "1", "coding" => "1" }, release: "1" }
    }

    expect(response).to redirect_to(project_automation_phases_path(project))
    settings = Automation::PhaseSettings.call(project.reload)
    expect(settings.phase_enabled?("discovery")).to be(true)
    expect(settings.phase_enabled?("coding")).to be(true)
    expect(settings.phase_enabled?("merge")).to be(false)
    expect(settings.release_enabled?).to be(true)
  end

  it "submits unchecked release and deployment controls as disabled" do
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "release_deployment" => true },
        Automation::PhaseSettings::RELEASE_KEY => true,
        Automation::PhaseSettings::DEPLOYMENT_KEY => true
      }
    )

    get project_automation_phases_path(project)
    form = Nokogiri::HTML(response.body)

    expect(form.at_css('input[type="hidden"][name="project[release]"][value="0"]')).to be_present
    expect(form.at_css('input[type="hidden"][name="project[deployment]"][value="0"]')).to be_present

    patch project_automation_phases_path(project), params: {
      project: { phases: { "release_deployment" => "1" }, release: "0", deployment: "0" }
    }

    settings = Automation::PhaseSettings.call(project.reload)
    expect(settings.release_enabled?).to be(false)
    expect(settings.deployment_enabled?).to be(false)
  end

  it "updates phase controls posted in the API settings shape" do
    patch project_automation_phases_path(project), params: {
      automation_phase_settings: { phases: { "merge" => true }, deployment: true }
    }

    expect(response).to redirect_to(project_automation_phases_path(project))
    settings = Automation::PhaseSettings.call(project.reload)
    expect(settings.phase_enabled?("merge")).to be(true)
    expect(settings.deployment_enabled?).to be(true)
  end

  it "reports when a continuation grant was no longer active" do
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), completed_at: Time.current)

    delete continuation_grant_project_automation_phases_path(project, grant), as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("revoked" => false, "grant_id" => grant.id)
  end

  it "explains a no-op continuation grant revocation in the HTML flow" do
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), revoked_at: Time.current)

    delete continuation_grant_project_automation_phases_path(project, grant)

    expect(response).to redirect_to(project_automation_phases_path(project))
    expect(flash[:notice]).to eq("Grant was no longer active; nothing to revoke.")
  end

  it "extends an active grant when the user may delegate the later endpoint" do # @spec AUTOMATION-PHASES-009
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), start_phase: "coding", endpoint: "coding")

    patch extend_continuation_grant_project_automation_phases_path(project, grant), params: { endpoint: "merge" }

    expect(response).to redirect_to(project_automation_phases_path(project))
    expect(grant.reload.endpoint).to eq("merge")
  end

  describe "delegated delivery authority" do
    let(:issue) { create(:issue, project:) }

    def authorize_review
      create(:bounded_delegated_action,
        project: project,
        issue: issue,
        action: "review",
        evidence: Automation::DelegatedActionAdmission.admission_evidence(
          work_item: issue, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
        ))
    end

    it "renders no delegation surface while the project gate is off" do # @spec PROJECT-DELEGATION-005
      authorize_review

      get project_automation_phases_path(project)

      expect(response.body).not_to include("Delegated delivery authority")
    end

    it "renders each authorization's effective authority from the shared policy" do # @spec PROJECT-DELEGATION-005
      FeatureFlags.enable!(:automation_phases, project:)
      FeatureFlags.enable!(:project_delegation, project:)
      project.update!(
        Automation::PhaseSettings::SETTINGS_KEY => {
          Automation::PhaseSettings::PHASES_KEY => { "coding" => true },
          Automation::PhaseSettings::RELEASE_KEY => false,
          Automation::PhaseSettings::DEPLOYMENT_KEY => false
        }
      )
      authorize_review

      get project_automation_phases_path(project)

      expect(response.body).to include("Delegated delivery authority")
      expect(response.body).to include("Effective authority")
      expect(response.body).to include("project phase defaults")
    end

    it "attributes authority to the legacy policy while the phase rollout is off" do # @spec PROJECT-DELEGATION-005
      FeatureFlags.enable!(:project_delegation, project:)
      authorize_review

      get project_automation_phases_path(project)

      expect(response.body).to include("Delegated delivery authority")
      expect(response.body).to include("legacy policy")
    end
  end
end
