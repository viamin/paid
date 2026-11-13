# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Agent Runs filters", system_driver: :rack_test, type: :system do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account: account, email: "owner@example.com", password: "password123") }
  let!(:project) { create(:project, account:, created_by: user) }

  def sign_in_as(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  # @spec AGENT-RUNS-INDEX-004
  it "renders the shareable multi-select filter UI with active state and reset" do
    create(:agent_run, project:, status: "queued", goal: "create_pr", trigger_type: "manual")
    create(:agent_run, project:, status: "running", goal: "create_issue", trigger_type: "automatic")

    sign_in_as(user)
    visit agent_runs_path(q: { status_in: %w[queued running], goal_in: %w[create_pr create_issue] })

    expect(page).to have_content("Active filters")
    expect(page).to have_css("label", text: "Search branch or workflow ID", visible: :all)
    expect(page).to have_css("input[name='q[branch_name_or_temporal_workflow_id_cont]']", visible: :all)
    expect(page).to have_css("select[name='q[status_in][]'][multiple] option[selected]", count: 2, visible: :all)
    expect(page).to have_css("select[name='q[goal_in][]'][multiple] option[selected]", count: 2, visible: :all)
    expect(page).to have_css("select[name='q[trigger_type_in][]'][multiple]", visible: :all)
    expect(page).to have_link("Reset filters", href: agent_runs_path, visible: :all)
  end
end
