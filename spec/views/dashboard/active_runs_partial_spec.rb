# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard/_active_runs", :no_db, type: :view do
  let(:project) { Struct.new(:full_name).new("acme/platform") }
  let(:issue) { Struct.new(:github_number, :title).new(42, "Show priority for active runs") }
  let(:run) do
    Struct.new(
      :status,
      :project,
      :issue,
      :custom_prompt,
      :source_pull_request_number,
      :id,
      :goal,
      :model_selection,
      :started_at,
      :duration,
      keyword_init: true
    ).new(
      status: "running",
      project: project,
      issue: issue,
      custom_prompt: nil,
      source_pull_request_number: nil,
      id: 123,
      goal: "create_pr",
      model_selection: nil,
      started_at: nil,
      duration: nil
    )
  end

  before do
    allow(view).to receive(:dom_id).with(run, :dashboard_row).and_return("agent_run_123_dashboard_row")
    allow(view).to receive(:agent_run_status_badge).with("running").and_return('<span>Running</span>'.html_safe)
    allow(view).to receive(:agent_run_priority_badge).with(run).and_return('<span>2 - P1</span>'.html_safe)
    allow(view).to receive(:agent_run_context_display).with(run).and_return('<span class="context-label">Issue #42</span>'.html_safe)
    allow(view).to receive(:agent_run_goal_display).with(run).and_return('<span class="goal-label">PR Creation</span>'.html_safe)
    allow(view).to receive(:agent_run_runner_display).with(run, anything).and_return("Codex")
    allow(view).to receive(:project_member_path).with(project).and_return("/projects/1")
    allow(view).to receive(:project_agent_run_member_path).with(project, run).and_return("/projects/1/agent_runs/123")
    allow(view).to receive(:dashboard_cancel_agent_run_member_path).with(run).and_return("/dashboard/runs/123/cancel")
  end

  it "renders the priority column and shared helper output" do
    render partial: "dashboard/active_runs", locals: { active_runs: [ run ] }

    fragment = Nokogiri::HTML.fragment(rendered)
    headers = fragment.css("thead th").map { |header| header.text.squish }
    row = fragment.at_css("tr#agent_run_123_dashboard_row")

    expect(headers).to include("Priority")
    expect(row).to be_present
    expect(row.text).to include("2 - P1")
    expect(row.text).to include("Issue #42")
    expect(row.text).to include("PR Creation")
  end
end
