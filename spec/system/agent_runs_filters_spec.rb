# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Agent Runs filters", system_driver: :rack_test, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project) { create(:project, account:, created_by: user) }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  # @spec AGENT-RUNS-INDEX-004 AGENT-RUNS-INDEX-005
  it "applies multiple statuses and goals, then resets the shareable query" do
    queued_pr = create(:agent_run, project:, status: "queued", goal: "create_pr")
    running_review = create(:agent_run, project:, status: "running", goal: "review", source_pull_request_number: 42)
    excluded_run = create(:agent_run, project:, status: "completed", goal: "create_issue")

    visit agent_runs_path(q: { status_in: [ "queued" ] })
    select "Queued", from: "Status"
    select "Running", from: "Status"
    select "Create PR", from: "Goal"
    select "PR Code Review", from: "Goal"
    click_button "Apply filters"

    expect(page).to have_current_path(/q\[status_in\]/)
    expect(page).to have_selector("#agent_run_#{queued_pr.id}")
    expect(page).to have_selector("#agent_run_#{running_review.id}")
    expect(page).not_to have_selector("#agent_run_#{excluded_run.id}")
    expect(page).to have_content("Active filters:")

    click_link "Reset filters"

    expect(page).to have_current_path(agent_runs_path)
    expect(page).to have_selector("#agent_run_#{excluded_run.id}")
    expect(page).not_to have_content("Active filters:")
  end
end
