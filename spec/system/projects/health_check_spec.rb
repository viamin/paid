# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Project health check page", system_driver: :rack_test, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let!(:project) { create(:project, account: account) }
  let(:populated_findings) do
    [
      HealthChecks::Finding.new(
        check: "HealthChecks::Checks::Project::EmptyAllowlist",
        scope: :project,
        severity: :error,
        message: "Allowed GitHub usernames is empty."
      ),
      HealthChecks::Finding.new(
        check: "HealthChecks::Checks::User::NoAgentRunners",
        scope: :user,
        severity: :warning,
        message: "No enabled runners for agent runs."
      )
    ]
  end

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  def cached_result(findings)
    HealthChecks::Result.new(findings: findings, checked_at: Time.current, duration_ms: 10)
  end

  it "shows findings grouped by scope in the populated state" do
    allow(HealthChecks::Cache).to receive(:read).and_return(cached_result(populated_findings))

    visit project_health_check_path(project)

    expect(page).to have_content("Health Check")
    expect(page).to have_content("Project")
    expect(page).to have_content("Empty Allowlist")
    expect(page).to have_content("Allowed GitHub usernames is empty.")
    expect(page).to have_content("User")
    expect(page).to have_content("No Agent Runners")
  end

  it "shows the all-clear card in the healthy state" do
    allow(HealthChecks::Cache).to receive(:read).and_return(cached_result([]))

    visit project_health_check_path(project)

    expect(page).to have_content("All checks passed")
  end

  it "enqueues a re-run when the Re-run button is clicked" do
    allow(HealthChecks::Cache).to receive(:read).and_return(nil)

    visit project_health_check_path(project)

    expect do
      click_button "Re-run checks"
    end.to have_enqueued_job(ProjectHealthCheckJob).with(project.id)
  end
end
