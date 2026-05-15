# frozen_string_literal: true

require "rails_helper"

RSpec.describe "projects/_agent_run", :no_db, type: :view do
  let(:project) { Struct.new(:to_param).new("1") }
  let(:agent_run) do
    Struct.new(
      :id,
      :to_param,
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
      to_param: "123",
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

  before do
    allow(view).to receive(:dom_id).with(agent_run).and_return("agent_run_123")
    allow(view).to receive(:agent_run_status_badge).with(agent_run.status).and_return('<span>Completed</span>'.html_safe)
    allow(view).to receive(:agent_run_priority_badge).with(agent_run).and_return('<span>2 - P1</span>'.html_safe)
    allow(view).to receive(:agent_run_goal_text).with(agent_run).and_return("Code Review")
    allow(view).to receive(:agent_run_context).with(agent_run).and_return({ type: :text, label: "PR #87", classes: "text-gray-700" })
    allow(view).to receive(:agent_run_provider_display).with(agent_run).and_return("Cursor Stable")
    allow(view).to receive(:time_ago_in_words).with(agent_run.created_at).and_return("5 minutes")
    allow(view).to receive(:safe_github_url?).and_return(false)
    allow(view).to receive(:project_agent_run_member_path).with(project, agent_run).and_return("/projects/1/agent_runs/123")
  end

  it "renders the member link without relying on route helper availability" do
    render partial: "projects/agent_run", locals: { agent_run:, project: }

    expect(rendered).to include("/projects/1/agent_runs/123")
    expect(rendered).to include(">View<")
  end
end
