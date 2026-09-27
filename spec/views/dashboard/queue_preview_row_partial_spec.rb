# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard/_queue_preview_row", :no_db, type: :view do
  let(:project) { Struct.new(:full_name).new("acme/platform") }
  let(:issue) { Struct.new(:github_number, :title).new(99, "Queue focus badge rendering") }
  let(:run) do
    Struct.new(
      :id,
      :project,
      :goal,
      :focus,
      :source_pull_request_number,
      :cancellable?,
      keyword_init: true
    ).new(
      id: 7,
      project: project,
      goal: "create_pr",
      focus: "general",
      source_pull_request_number: nil,
      cancellable?: false
    )
  end
  let(:entry) do
    Struct.new(:position, :run, keyword_init: true).new(position: 1, run: run)
  end

  before do
    allow(view).to receive(:dom_id).with(run, :queue_preview_row).and_return("agent_run_7_queue_preview_row")
    allow(view).to receive(:agent_run_priority_badge).with(run).and_return('<span>3 - P2</span>'.html_safe)
    allow(view).to receive(:agent_run_context_display).with(run).and_return('<span>Issue #99</span>'.html_safe)
    allow(view).to receive(:agent_run_focus_badge).with(run).and_return(nil)
    allow(view).to receive(:project_member_path).with(project).and_return("/projects/1")
    allow(view).to receive(:project_agent_run_member_path).with(project, run).and_return("/projects/1/agent_runs/7")
    policy_double = instance_double(AgentRunPolicy, cancel?: false)
    view.define_singleton_method(:policy) { |_| policy_double }
  end

  it "renders the goal label and skips the focus badge when the run is general" do
    render partial: "dashboard/queue_preview_row", locals: { entry: entry }

    row = Nokogiri::HTML.fragment(rendered).at_css("tr#agent_run_7_queue_preview_row")
    expect(row).to be_present
    expect(row.text).to include("PR Creation")
    expect(row.text).not_to include("Review Feedback")
  end

  it "renders the focus badge alongside the goal label when the run is focused" do
    allow(view).to receive(:agent_run_focus_badge).with(run).and_return('<span class="focus-badge">Review Feedback</span>'.html_safe)

    render partial: "dashboard/queue_preview_row", locals: { entry: entry }

    row = Nokogiri::HTML.fragment(rendered).at_css("tr#agent_run_7_queue_preview_row")
    expect(row).to be_present
    expect(row.text).to include("PR Creation")
    expect(row.text).to include("Review Feedback")
    expect(row.at_css(".focus-badge")).to be_present
  end

  it "gives the View and Cancel actions touch-target-sized hit areas" do
    allow(run).to receive(:cancellable?).and_return(true)
    policy_double = instance_double(AgentRunPolicy, cancel?: true)
    view.define_singleton_method(:policy) { |_| policy_double }

    render partial: "dashboard/queue_preview_row", locals: { entry: entry }

    row = Nokogiri::HTML.fragment(rendered).at_css("tr#agent_run_7_queue_preview_row")
    expect(row.css("a").find { |a| a.text == "View" }["class"]).to include("min-h-11")
    expect(row.css("button").find { |b| b.text == "Cancel" }["class"]).to include("min-h-11")
  end

  it "renders the context label as a sibling of <details> so it stays visible while details is closed" do
    wrapped = '<details class="relative inline-block">' \
      '<summary>icon</summary>' \
      '<span id="context_7" role="tooltip">Queue focus badge rendering</span>' \
      '</details>'.html_safe
    inner_link = '<a href="https://github.com/o/r/issues/99" target="_blank" rel="noopener noreferrer" ' \
      'class="text-indigo-600 hover:text-indigo-900" title="Queue focus badge rendering" ' \
      'aria-describedby="context_7">Issue #99</a>'.html_safe
    helper_output = "<span class=\"inline-flex items-center gap-1 relative\">#{inner_link}#{wrapped}</span>".html_safe
    allow(view).to receive(:agent_run_context_display).with(run).and_return(helper_output)

    render partial: "dashboard/queue_preview_row", locals: { entry: entry }

    row = Nokogiri::HTML.fragment(rendered).at_css("tr#agent_run_7_queue_preview_row")
    expect(row).to be_present
    details = row.at_css("details")
    expect(details).to be_present
    expect(row.at_css("a").ancestors).not_to include(details)
  end
end
