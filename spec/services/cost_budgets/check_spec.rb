# frozen_string_literal: true

require "rails_helper"

RSpec.describe CostBudgets::Check do
  let(:project) { create(:project) }

  describe ".call" do
    context "when no budgets exist" do
      it "returns allowed" do
        result = described_class.call(project)
        expect(result[:allowed]).to be true
      end
    end

    context "when budget is not exceeded" do
      it "returns allowed" do
        create(:cost_budget, project: project, limit_cents: 10_000, current_usage_cents: 5_000)
        result = described_class.call(project)
        expect(result[:allowed]).to be true
      end
    end

    context "when budget is exceeded" do
      it "returns blocked with reason" do
        create(:cost_budget, project: project, budget_type: "monthly", limit_cents: 10_000, current_usage_cents: 10_001)
        result = described_class.call(project)

        expect(result[:allowed]).to be false
        expect(result[:reason]).to include("monthly budget exceeded")
      end
    end

    context "with a per_run budget" do
      it "resets per_run usage before checking" do
        budget = create(:cost_budget, :per_run, project: project, limit_cents: 1_000, current_usage_cents: 999)
        result = described_class.call(project)

        expect(result[:allowed]).to be true
        expect(budget.reload.current_usage_cents).to eq(0)
      end
    end

    context "when a daily budget has stale usage from a previous period" do
      it "rolls over the period before checking" do
        budget = create(:cost_budget, :daily, project: project,
          limit_cents: 1_000, current_usage_cents: 1_500,
          period_started_at: 2.days.ago)
        result = described_class.call(project)

        expect(result[:allowed]).to be true
        expect(budget.reload.current_usage_cents).to eq(0)
      end
    end

    context "when multiple budgets are exceeded" do
      it "returns a deterministic reason based on budget_type ordering" do
        create(:cost_budget, project: project, budget_type: "monthly",
          limit_cents: 10_000, current_usage_cents: 10_001,
          period_started_at: Time.current.beginning_of_month)
        create(:cost_budget, project: project, budget_type: "daily",
          limit_cents: 1_000, current_usage_cents: 1_001,
          period_started_at: Time.current.beginning_of_day)

        result = described_class.call(project)

        expect(result[:allowed]).to be false
        expect(result[:reason]).to include("daily budget exceeded")
      end
    end

    context "when approaching threshold" do
      it "logs a warning and marks alert sent" do
        budget = create(:cost_budget, project: project, limit_cents: 10_000, current_usage_cents: 8_500)

        expect(Rails.logger).to receive(:warn).with(hash_including(message: "cost_budget.threshold_reached"))

        described_class.call(project)
        expect(budget.reload.alert_sent_at).to be_within(1.second).of(Time.current)
      end
    end
  end
end
