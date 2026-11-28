# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::CostDashboardStats do # @spec EXEC-USAGE-012
  it "uses one LLM aggregate for both summary windows and variable totals" do
    project = create(:project)
    run = create(:agent_run, project: project)
    create(:token_usage, agent_run: run, cost_cents: 30)

    queries = capture_queries { described_class.call(project: project) }
    windows = queries.grep(/FROM "token_usages"/).grep(/BETWEEN/)

    expect(windows.size).to eq(1)
  end

  it "returns zero for empty LLM windows" do
    summary = described_class.call(project: create(:project)).fetch(:summary)

    expect(summary.values_at(:cost_today_cents, :cost_this_month_cents,
      :total_variable_cost_today_cents, :total_variable_cost_this_month_cents)).to eq([ 0, 0, 0, 0 ])
  end

  it "preserves inclusive local boundaries and billable fallback without counting future rows" do
    Time.use_zone("America/New_York") do
      travel_to(Time.zone.local(2024, 3, 15, 12)) do
        project = create(:project)
        run = create(:agent_run, project: project)
        [ [ 11, Time.current.beginning_of_day ], [ 13, Time.current ], [ 17, Time.current.beginning_of_month ],
          [ 1000, Time.current.beginning_of_month - 1.second ], [ 2000, 1.second.from_now ] ].each do |cost, timestamp|
          create(:token_usage, agent_run: run, cost_cents: cost, created_at: timestamp)
        end
        create(:token_usage, agent_run: run, request_type: "run_summary", cost_cents: 999)

        summary = described_class.call(project: project).fetch(:summary)

        expect(summary[:cost_today_cents]).to eq(24)
        expect(summary[:cost_this_month_cents]).to eq(41)
        expect(summary[:total_variable_cost_today_cents]).to eq(24)
        expect(summary[:total_variable_cost_this_month_cents]).to eq(41)
      end
    end
  end
end
