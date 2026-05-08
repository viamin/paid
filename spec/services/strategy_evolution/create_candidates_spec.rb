# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyEvolution::CreateCandidates do
  describe ".call" do
    let(:account) { create(:account) }
    let(:strategy) { create(:orchestration_strategy, :review_settings, account: account, version: 3) }
    let(:mutation) do
      StrategyEvolution::Mutate::Mutation.new(
        configuration: strategy.configuration.deep_dup.tap do |config|
          config["methods"]["paid_agent"]["termination"]["timeout_minutes"] = 20
        end,
        strategy: "risk_reduction",
        reasoning: "Shorter timeout after repeated loops",
        expected_improvement: "Less guardrail thrash",
        diff: [ { "path" => "/methods/paid_agent/termination/timeout_minutes", "from" => 30, "to" => 20 } ],
        provenance: { "decision_summary" => { "decision_count" => 15, "success_rate" => 0.4 } }
      )
    end
    let(:strategy_snapshot) do
      {
        id: strategy.id,
        strategy_type: strategy.strategy_type,
        name: strategy.name,
        version: strategy.version,
        configuration: strategy.configuration
      }
    end

    it "persists inactive candidate versions with provenance metadata" do
      candidates = described_class.call(strategy_snapshot: strategy_snapshot, account: account, mutations: [ mutation ])

      expect(candidates.size).to eq(1)
      expect(candidates.first).not_to be_active
      expect(candidates.first.version).to eq(4)
      expect(candidates.first.configuration.dig("_evolution", "mutation_strategy")).to eq("risk_reduction")
      expect(candidates.first.configuration.dig("_evolution", "diff")).to include(
        include("path" => "/methods/paid_agent/termination/timeout_minutes")
      )
      expect(OrchestrationStrategy.active_for("review_settings", account: account)).to eq(strategy)
    end

    it "returns an empty array when no mutations are provided" do
      expect(described_class.call(strategy_snapshot: strategy_snapshot, account: account, mutations: [])).to eq([])
    end
  end
end
