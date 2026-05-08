# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicyEvolution::GenerateCandidates do
  describe ".call" do
    let(:strategy) do
      {
        id: 7,
        strategy_type: "feature_orchestration",
        version: 3,
        account_id: 11,
        configuration: OrchestrationStrategies::Defaults.feature_orchestration
      }
    end
    let(:analysis) do
      {
        prior_versions: [
          { id: 7, version: 3, active: true },
          { id: 5, version: 2, active: false }
        ],
        performance: {
          decision_count: 12,
          success_count: 8,
          failure_count: 4,
          success_rate: 0.6667,
          lookback_days: 45,
          decision_type_counts: { "planning_outcome" => 7 },
          outcome_counts: { "sub_issues_created" => 6, "parallelization_failed" => 2 },
          policy_source_counts: { "feature_orchestration" => 9 },
          average_task_count: 3.4
        },
        sample_successes: [ { id: 101 } ],
        sample_failures: [ { id: 202 } ]
      }
    end
    let(:mutation) do
      StrategyEvolution::Mutate::Mutation.new(
        configuration: strategy[:configuration].deep_dup,
        strategy: "risk_reduction",
        reasoning: "Reduce over-parallelization",
        expected_improvement: "Fewer failed plans",
        diff: [ { "path" => "/decomposition/max_tasks", "from" => 20, "to" => 12 } ],
        provenance: { "source_version" => 3 }
      )
    end

    before do
      allow(StrategyEvolution::Mutate).to receive(:call).and_return([ mutation ])
    end

    it "adds reviewable coordination provenance to each candidate mutation" do
      result = described_class.call(strategy: strategy, analysis: analysis, options: { mutation_count: 1 })

      expect(result.size).to eq(1)
      expect(result.first.provenance).to include(
        "generated_by" => "CoordinationPolicyEvolution::GenerateCandidates",
        "policy_type" => "feature_orchestration",
        "sampled_decision_ids" => [ 101, 202 ]
      )
      expect(result.first.provenance.fetch("prior_versions")).to include(
        include(id: 7, version: 3, active: true)
      )
      expect(result.first.provenance.fetch("measured_outcomes")).to include(
        decision_count: 12,
        failure_count: 4,
        success_rate: 0.6667
      )
    end
  end
end
