# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicyEvolution::CreateCandidates do
  describe ".call" do
    let(:account) { create(:account) }
    let(:strategy) { create(:orchestration_strategy, :feature_orchestration, account: account, version: 3) }
    let(:mutation) do
      StrategyEvolution::Mutate::Mutation.new(
        configuration: strategy.configuration.deep_dup.tap do |config|
          config["decomposition"] = { "max_tasks" => 12 }
        end,
        strategy: "risk_reduction",
        reasoning: "Reduce large decompositions",
        expected_improvement: "More reviewable plans",
        diff: [ { "path" => "/decomposition/max_tasks", "from" => nil, "to" => 12 } ],
        provenance: { "sampled_decision_ids" => [ 101, 202 ] }
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

    it "persists inactive candidates with explicit pending approval metadata" do
      candidates = described_class.call(strategy_snapshot: strategy_snapshot, account: account, mutations: [ mutation ])

      expect(candidates.size).to eq(1)
      expect(candidates.first).not_to be_active
      expect(candidates.first.version).to eq(4)
      expect(candidates.first.configuration.dig("_evolution", "approval")).to eq(
        "required" => true,
        "status" => "pending_review",
        "auto_promote" => false
      )
      expect(candidates.first.configuration.dig("_evolution", "provenance", "sampled_decision_ids")).to eq([ 101, 202 ])
      expect(OrchestrationStrategy.active_for("feature_orchestration", account: account)).to eq(strategy)
    end
  end
end
