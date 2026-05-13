# frozen_string_literal: true

require "rails_helper"

RSpec.describe "agent_runs/_index_table", :no_db, type: :view do
  let(:project) { Struct.new(:name).new("Platform") }
  let(:run) do
    Struct.new(
      :id,
      :project,
      :status,
      :duration_seconds,
      :started_at,
      :created_at,
      :pull_request_url,
      :review_url,
      :created_issue_url,
      :created_issue_number,
      keyword_init: true
    ) do
      def running? = false

      def cross_repo_issue_pair? = false
    end.new(
      id: 123,
      project: project,
      status: "completed",
      duration_seconds: 12,
      started_at: nil,
      created_at: Time.zone.parse("2026-05-13 00:00:00 UTC"),
      pull_request_url: nil,
      review_url: nil,
      created_issue_url: nil,
      created_issue_number: nil
    )
  end
  let(:pagy) { Struct.new(:series_nav).new("") }

  before do
    allow(view).to receive(:sort_link_to) { |label, *_args| label }
    allow(view).to receive(:dom_id).with(run).and_return("agent_run_123")
    allow(view).to receive(:agent_run_provider_displays).with([ run ]).and_return({ run.id => "Cursor Stable" })
    allow(view).to receive(:agent_run_status_badge).with(run.status).and_return('<span>Completed</span>'.html_safe)
    allow(view).to receive(:agent_run_priority_badge).with(run).and_return('<span>2 - P1</span>'.html_safe)
    allow(view).to receive(:agent_run_provider_display).with(run, { run.id => "Cursor Stable" }).and_return("Cursor Stable")
    allow(view).to receive(:agent_run_goal_display).with(run).and_return('<span class="goal-label">Code Review</span>'.html_safe)
    allow(view).to receive(:agent_run_context_display).with(run).and_return('<span class="context-label">PR #87</span>'.html_safe)
    allow(view).to receive(:time_ago_in_words).with(run.created_at).and_return("5 minutes")
    allow(view).to receive(:safe_github_url?).and_return(false)
    allow(view).to receive(:project_agent_run_path).with(project, run).and_return("/projects/1/agent_runs/123")
  end

  it "renders a single Provider column and keeps goal content distinct from context" do
    render partial: "agent_runs/index_table", locals: {
      agent_runs: [ run ],
      q: nil,
      pagy: pagy,
      show_project: false,
      project: project
    }

    fragment = Nokogiri::HTML.fragment(rendered)
    headers = fragment.css("thead th").map { |header| header.text.squish }
    row = fragment.at_css("tr#agent_run_123")

    expect(headers.count("Provider")).to eq(1)
    expect(row).to be_present

    goal_index = headers.index("Goal")
    context_index = headers.index("Context")
    provider_index = headers.index("Provider")

    expect(row.css("td")[goal_index].text.squish).to eq("Code Review")
    expect(row.css("td")[context_index].text.squish).to eq("PR #87")
    expect(row.css("td")[provider_index].text.squish).to eq("Cursor Stable")
  end
end
