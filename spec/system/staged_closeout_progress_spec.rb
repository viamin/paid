# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec STAGED-CLOSEOUT-ADOPTION-014
RSpec.describe "Staged closeout progress", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:issue) { create(:issue, project:) }

  around do |example|
    prior = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = "fixture-browser-confirmed-target"
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = prior
    Warden.test_reset!
  end

  before do
    login_as owner, scope: :user
    FeatureFlags.enable!(:automation_phases, project:)
    Automation::PhaseSettings::Update.call(project:, user: owner, params: { "phases" => { "operations" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
    create(:agent_run, :completed, project:, issue:, goal: "analyze_issue", result_commit_sha: nil,
      reconciliation: { "assessment" => {
        "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
        "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
        "criteria" => [ { "criterion" => "Browser planning-hold observation", "state" => "unmet" } ], "gaps" => []
      } })
    StagedCloseoutAdoption::Mappings.approve(project:, actor: owner, issue:, attributes: {
      criterion_key: "Browser planning-hold observation", stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: "agent_planning_hold_reconciliation_closed_count",
      environment_class: Rails.env.to_s, freshness_seconds: 60 })
  end

  def check_queued_progress
    within("[data-testid='inbox-progress']") do
      expect(page).to have_text("Acceptance verification")
      expect(page).to have_text("Browser planning-hold observation")
      expect(page).to have_text("Run state: Queued")
      expect(page).to have_text("fixture-browser-confirmed-target")
      expect(page).to have_css("[data-progress-state='waiting']")
    end
  end

  def check_observed_progress
    within("[data-testid='inbox-progress']") do
      expect(page).to have_text("Outcome: Observed")
      expect(page).to have_text("Observed values:")
      expect(page).to have_text("Expires at:")
      expect(page).to have_text("Outcome: Open")
    end
  end

  def check_expired_progress
    within("[data-testid='inbox-progress']") do
      expect(page).to have_css("[data-progress-state='stale']")
      expect(page).to have_text("attempt allowance is exhausted")
    end
  end

  def capture_responsive_progress
    [ 320, 1280 ].each do |width|
      page.current_window.resize_to(width, 1000)
      page.execute_script("document.querySelector('[data-testid=inbox-progress]').scrollIntoView({block: 'start'})")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1")).to be(true)
    end
    page.save_screenshot("/tmp/paid-overnight-5078-progress-browser.png")
  end

  def execute_fixture_verification(run)
    # Browser/Cable requests share the fixture's PostgreSQL session. Serialize
    # the inline worker with their tenant-context changes, as HTTP already does.
    CapybaraTenantContext.with_fixture_session do
      CloseoutVerificationJob.perform_now(run.id)
      expect(run.reload.status).to eq("completed")
    end
  end

  it "shows queued, actually observed and expired evidence without declaring accepted closure" do
    run = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
    visit project_staged_closeout_adoption_path(project, issue_id: issue.id)
    check_queued_progress
    execute_fixture_verification(run)
    visit project_staged_closeout_adoption_path(project, issue_id: issue.id)
    check_observed_progress
    travel 61.seconds do
      visit project_staged_closeout_adoption_path(project, issue_id: issue.id)
      check_expired_progress
    end
    CapybaraTenantContext.with_fixture_session { expect(issue.reload.github_state).to eq("open") }
    capture_responsive_progress
  end
end
