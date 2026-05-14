# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicyEvolution::GenerateCandidates, :no_db do
  describe ".call" do
    let(:policy) do
      {
        id: 7,
        policy_type: "decomposition",
        policy_key: "feature_decomposition",
        version: 3,
        account_id: 11,
        configuration: OrchestrationStrategies::Defaults.feature_orchestration
      }
    end
    let(:analysis) do
      {
        prior_versions: [
          { id: 7, version: 3, status: "active" },
          { id: 5, version: 2, status: "retired" }
        ],
        performance: {
          decision_count: 12,
          classified_decision_count: 9,
          success_count: 8,
          failure_count: 4,
          noop_count: 3,
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
        configuration: policy[:configuration].deep_dup,
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
      result = described_class.call(policy: policy, analysis: analysis, options: { mutation_count: 1 })

      expect(result.size).to eq(1)
      expect(result.first.provenance).to include(
        "generated_by" => "CoordinationPolicyEvolution::GenerateCandidates",
        "policy_type" => "decomposition",
        "policy_key" => "feature_decomposition",
        "sampled_decision_ids" => [ 101, 202 ]
      )
      expect(result.first.provenance.fetch("prior_versions")).to include(
        include(id: 7, version: 3, status: "active")
      )
      expect(result.first.provenance.fetch("measured_outcomes")).to include(
        decision_count: 12,
        classified_decision_count: 9,
        failure_count: 4,
        noop_count: 3,
        success_rate: 0.6667
      )
    end
  end
end
