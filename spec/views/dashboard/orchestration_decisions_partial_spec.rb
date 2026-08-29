# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard/_orchestration_decisions", :no_db, type: :view do
  let(:report) do
    {
      summary: {
        total_count: 12,
        successful_count: 7,
        noop_count: 3,
        failed_count: 2,
        project_count: 4,
        actor_count: 2,
        linked_agent_run_count: 5,
        completed_run_count: 4,
        failed_run_count: 1
      },
      status_breakdown: [
        { decision_status: "applied", analytics_group: "successful", total_count: 7 }
      ],
      by_project: [
        {
          project_name: "Paid",
          project_full_name: "viamin/paid",
          total_count: 12,
          decision_type_count: 2,
          actor_count: 2,
          successful_count: 7,
          failed_count: 2
        }
      ],
      by_decision_type: [
        {
          decision_type: "retry_policy",
          total_count: 12,
          project_count: 4,
          actor_count: 2,
          failed_count: 2,
          completed_run_count: 4
        }
      ],
      outcome_by_decision_type: [
        {
          decision_type: "retry_policy",
          successful_count: 7,
          noop_count: 3,
          failed_count: 2,
          total_count: 12
        }
      ],
      by_actor: [
        {
          actor: "orchestrator",
          total_count: 12,
          project_count: 4,
          decision_type_count: 2,
          successful_count: 7,
          failed_count: 2
        }
      ],
      daily_volume: [
        { day: Date.new(2026, 8, 1), successful_count: 7, noop_count: 3, failed_count: 2 }
      ]
    }
  end

  before { allow(view).to receive(:turbo_frame_tag).and_yield }

  def metric_list
    render partial: "dashboard/orchestration_decisions",
           locals: { report: report, time_range: "30d" }
    Nokogiri::HTML5.fragment(rendered).css("dl").first
  end

  it "renders the metric cards as a definition list" do
    expect(metric_list).to be_present
    expect(metric_list.text).to include("Total Decisions")
  end

  it "restricts definition list groups to dt and dd elements" do
    children = metric_list.element_children

    expect(children.map(&:name).uniq).to eq([ "div" ])
    expect(children.flat_map { |group| group.element_children.map(&:name) }.uniq)
      .to match_array(%w[dt dd])
  end

  it "keeps the supporting card captions readable as definitions" do
    expect(metric_list.text).to include("Includes applied, deferred, and auto-resolved decisions.")
    expect(metric_list.text).to include("4 projects contributing context")
  end
end
