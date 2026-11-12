# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Agent Runs filtering", system_driver: :rack_test, type: :system do
  # @spec AGENT-RUNS-INDEX-004, AGENT-RUNS-INDEX-005
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project) { create(:project, account:, created_by: user) }

  before do
    create(:agent_run, project:, status: "queued", agent_type: "codex", goal: "create_pr", trigger_type: "manual")
    create(:agent_run, project:, status: "running", agent_type: "claude_code", goal: "create_issue", trigger_type: "automatic")
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  it "offers keyboard-accessible multi-select controls, active state, and reset on both run indexes" do
    [ agent_runs_path(q: { status_in: [ "queued", "running" ] }), project_agent_runs_path(project, q: { status_in: [ "queued", "running" ] }) ].each do |path|
      visit path
      document = Nokogiri::HTML(page.html)

      expect(document.at_css("label[for='q_branch_name_or_temporal_workflow_id_cont']").text).to eq("Search runs")
      expect(document.at_css("select[name='q[status_in][]'][multiple]")).to be_present
      expect(document.at_css("select[name='q[agent_type_in][]'][multiple]")).to be_present
      expect(document.at_css("select[name='q[goal_in][]'][multiple]")).to be_present
      expect(document.at_css("select[name='q[trigger_type_in][]'][multiple]")).to be_present
      expect(document.css("a").find { |link| link.text.squish == "Clear" }["href"]).to eq(path.split("?").first)
      expect(document.text).to include("Active filters are applied.")
    end
  end
end
