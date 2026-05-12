# frozen_string_literal: true

require "rails_helper"

RSpec.describe "agent_runs/_index_table", :no_db, type: :view do
  let(:project) { Struct.new(:name).new("Platform") }
  let(:issue) { Struct.new(:title).new("Fix flaky webhook retry handling") }
  let(:run) do
    Struct.new(
      :id,
      :status,
      :project,
      :issue,
      :goal,
      :duration_seconds,
      :started_at,
      :created_at,
      :pull_request_url,
      :review_url,
      :created_issue_url,
      :created_issue_number,
      :cross_repo_issue_pair?,
      keyword_init: true
    ).new(
      id: 123,
      status: "completed",
      project: project,
      issue: issue,
      goal: "create_pr",
      duration_seconds: 42,
      started_at: nil,
      created_at: Time.utc(2026, 5, 12, 7, 0, 0),
      pull_request_url: nil,
      review_url: nil,
      created_issue_url: nil,
      created_issue_number: nil,
      cross_repo_issue_pair?: false
    )
  end
  let(:pagy) { double(series_nav: "") }
  let(:q) { instance_double(Ransack::Search) }

  before do
    allow(view).to receive(:sort_link_to) { |label, *_args| label }
    allow(view).to receive(:agent_run_provider_displays).with([ run ]).and_return({ run.id => "Codex" })
    allow(view).to receive(:agent_run_provider_display).with(run, { run.id => "Codex" }).and_return("Codex")
    allow(view).to receive(:agent_run_status_badge).with("completed").and_return('<span>Completed</span>'.html_safe)
    allow(view).to receive(:agent_run_priority_badge).with(run).and_return('<span>2 - P1</span>'.html_safe)
    allow(view).to receive(:agent_run_goal_display).with(run).and_return('<span title="Create PR">Create PR</span>'.html_safe)
    allow(view).to receive(:agent_run_context_display).with(run).and_return('<a title="Fix flaky webhook retry handling">Fix flaky webhook retry handling</a>'.html_safe)
    allow(view).to receive(:time_ago_in_words).with(run.created_at).and_return("5 minutes")
    allow(view).to receive(:project_path).with(project).and_return("/projects/1")
    allow(view).to receive(:project_agent_run_path).with(project, run).and_return("/projects/1/agent_runs/123")
    allow(view).to receive(:safe_github_url?).and_return(false)
  end

  it "renders one provider column and keeps issue details in the context column" do
    render partial: "agent_runs/index_table", locals: { agent_runs: [ run ], q: q, pagy: pagy, show_project: true }

    fragment = Nokogiri::HTML.fragment(rendered)
    headers = fragment.css("thead th").map { |header| header.text.squish }
    row_cells = fragment.at_css("tbody tr").css("td").map { |cell| cell.text.squish }

    expect(headers.count("Provider")).to eq(1)
    expect(row_cells.count("Codex")).to eq(1)
    expect(row_cells).to include("Create PR")
    expect(row_cells).to include("Fix flaky webhook retry handling")
  end
end
