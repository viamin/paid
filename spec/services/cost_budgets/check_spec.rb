# frozen_string_literal: true

require "rails_helper"

RSpec.describe CostBudgets::Check do
  let(:project) { create(:project) }

  describe "pre-flight enforcement" do
    let(:agent_run) { create(:agent_run, :running, project: project) }

    it "blocks when hard_stop budget is exceeded" do
      create(:cost_budget, :hard_stop, project: project, budget_type: "daily",
        limit_cents: 1_000, current_usage_cents: 1_500,
        period_started_at: Time.current.beginning_of_day)

      result = described_class.call(project)

      expect(result[:allowed]).to be false
      expect(result[:reason]).to include("daily budget exceeded")
    end

    it "allows when only alert-mode budgets are exceeded" do
      create(:cost_budget, project: project, budget_type: "daily",
        enforcement_mode: "alert",
        limit_cents: 1_000, current_usage_cents: 1_500,
        period_started_at: Time.current.beginning_of_day)

      result = described_class.call(project)

      expect(result[:allowed]).to be true
    end
  end

  describe "TokenUsageTracker mid-run enforcement" do
    let(:agent_run) { create(:agent_run, :running, project: project) }

    before do
      allow(AgentRuns::Cancel).to receive(:call)
    end

    it "cancels running agent when hard_stop daily budget is exceeded" do
      create(:cost_budget, :hard_stop, :daily, project: project,
        limit_cents: 100, current_usage_cents: 90,
        period_started_at: Time.current.beginning_of_day)

      TokenUsageTracker.track(
        agent_run: agent_run,
        usage: { tokens_input: 1_000_000, tokens_output: 1_000_000 }
      )

      expect(agent_run.reload.status).to eq("failed")
      expect(agent_run.error_message).to include("Budget enforcement")
      expect(AgentRuns::Cancel).to have_received(:call).with(
        agent_run: agent_run, skip_status_update: true
      )
    end

    it "cancels running agent when hard_stop per_run budget is exceeded" do
      create(:cost_budget, :per_run, :hard_stop, project: project,
        limit_cents: 100, current_usage_cents: 0)

      TokenUsageTracker.track(
        agent_run: agent_run,
        usage: { tokens_input: 1_000_000, tokens_output: 1_000_000 }
      )

      expect(agent_run.reload.status).to eq("failed")
      expect(agent_run.error_message).to include("Budget enforcement")
    end

    it "does not cancel when alert-mode budget is exceeded" do
      create(:cost_budget, :daily, project: project,
        enforcement_mode: "alert",
        limit_cents: 100, current_usage_cents: 90,
        period_started_at: Time.current.beginning_of_day)

      TokenUsageTracker.track(
        agent_run: agent_run,
        usage: { tokens_input: 1_000_000, tokens_output: 1_000_000 }
      )

      expect(agent_run.reload.status).to eq("running")
      expect(AgentRuns::Cancel).not_to have_received(:call)
    end

    it "respects grace buffer before cancelling" do
      create(:cost_budget, :hard_stop, :daily, project: project,
        limit_cents: 1_800, current_usage_cents: 0,
        grace_buffer_percent: 20,
        period_started_at: Time.current.beginning_of_day)

      # This will add 1800 cents, hitting the limit but within 20% grace (effective limit: 2160)
      TokenUsageTracker.track(
        agent_run: agent_run,
        usage: { tokens_input: 1_000_000, tokens_output: 1_000_000 }
      )

      expect(agent_run.reload.status).to eq("running")
      expect(AgentRuns::Cancel).not_to have_received(:call)
    end
  end
end
