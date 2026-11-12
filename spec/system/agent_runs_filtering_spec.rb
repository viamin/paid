# frozen_string_literal: true

require "rails_helper"

# @spec AGENT-RUNS-INDEX-004 AGENT-RUNS-INDEX-005
RSpec.describe "Agent Runs filtering", system_driver: :rack_test, type: :system do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account:, email: "runs@example.com", password: "password123") }
  let!(:project) { create(:project, account:, created_by: user) }

  before do
    create(:agent_run, :with_custom_prompt, project:, status: "queued", custom_prompt: "Repair OAuth callback")
    create(:agent_run, :with_custom_prompt, project:, status: "completed", custom_prompt: "Unrelated cleanup")
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  it "filters multiple statuses with search and offers a reset URL" do
    visit agent_runs_path
    find("summary", text: "Filters").click
    select "Queued", from: "Status"
    select "Completed", from: "Status"
    fill_in "Search run text", with: "OAuth"
    click_button "Apply filters"

    expect(page).to have_content("Repair OAuth callback")
    expect(page).to have_no_content("Unrelated cleanup")
    expect(page.current_url).to include("status_in")
    expect(page).to have_link("Reset filters", href: agent_runs_path, visible: :all)
  end
end
