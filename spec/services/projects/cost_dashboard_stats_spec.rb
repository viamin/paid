# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::CostDashboardStats do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, total_cost_cents: 5000, total_tokens_used: 100_000) }

  describe ".call" do
    subject(:stats) { described_class.call(project: project) }

    it "returns summary with cost totals" do
      expect(stats[:summary][:total_cost_cents]).to eq(5000)
      expect(stats[:summary][:total_tokens]).to eq(100_000)
    end

    it "calculates today and monthly costs" do
      travel_to(Time.zone.local(2024, 1, 15, 12, 0, 0)) do
        run = create(:agent_run, project: project, status: "completed", cost_cents: 300)
        create(:token_usage, agent_run: run, cost_cents: 300, request_type: "agent")

        result = described_class.call(project: project)
        expect(result[:summary][:cost_today_cents]).to eq(300)
        expect(result[:summary][:cost_this_month_cents]).to eq(300)
      end
    end

    it "calculates average cost per run" do
      create(:agent_run, project: project, status: "completed", cost_cents: 400)
      create(:agent_run, project: project, status: "completed", cost_cents: 600)

      result = described_class.call(project: project)
      expect(result[:summary][:avg_cost_per_run_cents]).to eq(500)
    end

    it "returns cost breakdown by model" do
      run = create(:agent_run, project: project)
      create(:token_usage, agent_run: run, cost_cents: 200, llm_model: "claude-3-opus", request_type: "agent")
      create(:token_usage, agent_run: run, cost_cents: 100, llm_model: "claude-3-haiku", request_type: "agent")

      result = described_class.call(project: project)
      models = result[:cost_by_model].to_h
      expect(models["claude-3-opus"]).to eq(200)
      expect(models["claude-3-haiku"]).to eq(100)
    end

    it "returns a full 30-day daily cost array with zero-filled gaps" do
      travel_to(Time.zone.local(2024, 6, 15, 12, 0, 0)) do
        run = create(:agent_run, project: project)
        create(:token_usage, agent_run: run, cost_cents: 150, request_type: "agent")

        result = described_class.call(project: project)
        daily = result[:daily_costs]
        expect(daily).to be_an(Array)
        expect(daily.length).to eq(30)
        expect(daily.first.first).to eq(Date.new(2024, 5, 17))
        expect(daily.last.first).to eq(Date.new(2024, 6, 15))
        expect(daily.last.last).to eq(150)
        # Days without usage should be zero-filled
        expect(daily[0..28].map(&:last)).to all(eq(0))
      end
    end

    it "returns budget information with usage for daily budgets" do
      create(:cost_budget, :daily, project: project, limit_cents: 1000, current_usage_cents: 500)

      result = described_class.call(project: project)
      expect(result[:budgets].length).to eq(1)
      budget = result[:budgets].first
      expect(budget[:budget_type]).to eq("daily")
      expect(budget[:usage_percent]).to eq(50.0)
      expect(budget[:current_usage_cents]).to eq(500)
      expect(budget[:remaining_cents]).to eq(500)
    end

    it "omits period-based usage fields for per_run budgets" do
      create(:cost_budget, project: project, budget_type: "per_run", limit_cents: 2000)

      result = described_class.call(project: project)
      budget = result[:budgets].first
      expect(budget[:budget_type]).to eq("per_run")
      expect(budget[:limit_cents]).to eq(2000)
      expect(budget).not_to have_key(:usage_percent)
      expect(budget).not_to have_key(:current_usage_cents)
      expect(budget).not_to have_key(:remaining_cents)
    end
  end
end
