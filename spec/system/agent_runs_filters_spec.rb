# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Agent Runs filters", system_driver: :rack_test, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  # @spec AGENT-RUNS-INDEX-004
  it "filters account runs with multi-select controls, preserves the GET query, and resets" do
    matching_run, excluded_run = filter_runs

    visit agent_runs_path
    find("summary", text: "Filters").click
    fill_in "Search runs", with: "system-search"
    select "Queued", from: "Status"
    select "Codex", from: "Agent"
    select "Create PR", from: "Goal"
    select "Manual", from: "Trigger"
    click_button "Apply filters"

    expect(page).to have_current_path(/q\[status_in\]\[\]=queued/)
    expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(matching_run)}")
    expect(page).not_to have_css("##{ActionView::RecordIdentifier.dom_id(excluded_run)}")
    expect(page).to have_content("Active filters")

    find("summary", text: "Filters").click
    click_link "Reset filters"
    expect(page).to have_current_path(agent_runs_path)
    expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(matching_run)}")
    expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(excluded_run)}")
  end

  private

  def filter_runs
    [
      create(:agent_run, :with_git_context, project:, status: "queued", agent_type: "codex",
        goal: "create_pr", trigger_type: "manual", branch_name: "feature/system-search"),
      create(:agent_run, :with_git_context, project:, status: "completed", agent_type: "cursor",
        goal: "create_issue", trigger_type: "automatic", branch_name: "feature/system-other")
    ]
  end
end
