# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyEvolution::PrepareInputs do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let!(:strategy) { create(:orchestration_strategy, :review_settings, account: account, version: 2) }
    let!(:older_version) { create(:orchestration_strategy, :review_settings, account: account, version: 1, active: false) }

    before do
      create(
        :orchestration_decision,
        project: project,
        agent_run: create(:agent_run, :completed, project: project),
        decision_type: "queue_review_run",
        actor: "auto_review"
      )
      create(
        :orchestration_decision,
        project: project,
        agent_run: create(:agent_run, :paused, project: project),
        decision_type: "escalate",
        actor: "auto_review"
      )
      other_project = create(:project)
      create(:orchestration_decision, project: other_project, agent_run: create(:agent_run, :failed, project: other_project))
    end

    it "collects the current strategy, recent versions, and account-scoped outcomes" do
      result = described_class.call(strategy_type: "review_settings", account: account, min_decisions: 2)

      expect(result[:strategy]).to include(id: strategy.id, version: 2, strategy_type: "review_settings")
      expect(result[:prior_versions].map { |row| row[:id] }).to include(strategy.id, older_version.id)
      expect(result.dig(:performance, :decision_count)).to eq(2)
      expect(result.dig(:performance, :success_count)).to eq(1)
      expect(result.dig(:performance, :failure_count)).to eq(1)
      expect(result.dig(:performance, :lookback_days)).to eq(60)
      expect(result.dig(:performance, :guardrail_violation_types)).to include("loop_detected" => 1)
      expect(result[:sample_successes].size).to eq(1)
      expect(result[:sample_failures].size).to eq(1)
    end
  end
end
