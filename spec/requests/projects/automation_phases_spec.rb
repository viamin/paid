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

  it "renders delegated delivery authority from the shared projection" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:project_delegation, project:)
    work_item = create(:issue, project:)
    create(:bounded_delegated_action, project:, issue: work_item, action: "review",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: work_item, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
    revoked = create(:bounded_delegated_action, project:, issue: work_item, action: "repair",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: work_item, action: "repair", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
    revoked.update!(status: "revoked")

    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Delegated delivery actions")
    expect(response.body).to include("review")
    expect(response.body).to include("in force")
    expect(response.body).to include("revoked")
  end

  it "states when the project has no delegated delivery actions" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:project_delegation, project:)
    get project_automation_phases_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("No delegated delivery actions")
  end

  it "hides delegated delivery actions until the project opts in" do # @spec PROJECT-DELEGATION-005
    get project_automation_phases_path(project)

    expect(response.body).not_to include("Delegated delivery actions")
  end

  it "attributes fallback authority to the legacy policy" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:project_delegation, project:)
    work_item = create(:issue, project:)
    create(:bounded_delegated_action, project:, issue: work_item, action: "review",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item:, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))

    get project_automation_phases_path(project)

    expect(Nokogiri::HTML(response.body).text.squish).to include("permitted through legacy policy")
  end
end
