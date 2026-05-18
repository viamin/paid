# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard/_knowledge_widget", :no_db, type: :view do
  let(:knowledge_stats) do
    {
      projects_indexed: 1,
      projects_total: 2,
      total_artifacts: 5,
      stale_artifacts: 1,
      stale_percent: 17,
      artifacts_by_type: [],
      last_collection_at: nil,
      operational_status: "degraded",
      provider_health: {
        embedding: [
          {
            runner: "openai",
            available: true,
            circuit_state: "closed",
            rate_limited: false,
            rate_limited_until: nil,
            recent_failures: 0
          }
        ],
        chat: [
          {
            runner: "claude",
            available: false,
            circuit_state: "open",
            rate_limited: false,
            rate_limited_until: nil,
            recent_failures: 2
          }
        ]
      },
      token_usage_summary: [],
      knowledge_usage_summary: [],
      usage_by_goal: [],
      pipeline_metrics: {
        "embedding" => {
          total_runs: 1,
          successful_runs: 1,
          failed_runs: 0,
          success_rate: 100.0,
          avg_duration_seconds: 1.25,
          runner_distribution: [
            {
              runner: "openai",
              run_count: 1,
              success_rate: 100.0,
              avg_duration_seconds: 1.25
            }
          ]
        }
      }
    }
  end

  before do
    allow(view).to receive(:turbo_frame_tag).and_yield
    allow(view).to receive(:knowledge_search_path).and_return("/knowledge/search")
  end

  it "renders runner health copy and runner names from the stats payload" do
    render partial: "dashboard/knowledge_widget", locals: { knowledge_stats: knowledge_stats }

    expect(rendered).to include("Runner Health")
    expect(rendered).to include("knowledge chat and embedding runners")
    expect(rendered).to include("one runner group remains available")
    expect(rendered).to include("openai")
    expect(rendered).to include("claude")
    expect(rendered).to include("1 runner")
  end

  it "renders pipeline runner distribution rows using runner keys" do
    render partial: "dashboard/knowledge_widget", locals: { knowledge_stats: knowledge_stats }

    expect(rendered).to include("LLM Pipeline Metrics (Last 30 Days)")
    expect(rendered).to include("Runner")
    expect(rendered).to include("openai")
  end
end
