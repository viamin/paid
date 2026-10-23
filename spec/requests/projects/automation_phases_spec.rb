# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-015 @spec AUTOMATION-PHASES-016
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
end
