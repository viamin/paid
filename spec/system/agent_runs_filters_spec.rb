# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Agent Runs filters", system_driver: :rack_test, type: :system do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project) { create(:project, account:, created_by: user) }

  before do
    create(:agent_run, :with_custom_prompt, project:, status: "queued", goal: "create_pr", custom_prompt: "Investigate release blocker")
    create(:agent_run, :with_custom_prompt, project:, status: "completed", goal: "create_issue", custom_prompt: "Prepare release notes")

    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  # @spec AGENT-RUNS-INDEX-004
  it "provides labelled multi-select controls, exposes active filters, and resets them" do
    visit agent_runs_path(q: { status_in: [ "queued" ] })

    expect(page).to have_select("Status", multiple: true)
    expect(page).to have_select("Agent", multiple: true)
    expect(page).to have_select("Goal", multiple: true)
    expect(page).to have_select("Runner", multiple: true)
    expect(page).to have_select("Trigger", multiple: true)
    expect(page).to have_field("Search run context")

    visit agent_runs_path(q: { status_in: [ "queued" ], run_text_cont: "release blocker" })

    expect(page).to have_content("Active filters:")
    click_link "Reset filters"

    expect(page).to have_current_path(agent_runs_path)
    expect(page).not_to have_content("Active filters:")
  end
end
