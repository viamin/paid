# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyEvolution::GenerateCandidates do
  describe ".call" do
    let(:strategy) do
      {
        id: 12,
        strategy_type: "review_settings",
        version: 3,
        account_id: 7,
        configuration: OrchestrationStrategies::Defaults.review_settings
      }
    end
    let(:analysis) do
      {
        prior_versions: [
          { id: 12, version: 3, active: true },
          { id: 9, version: 2, active: false }
        ],
        performance: {
          decision_count: 12,
          min_decisions: 10,
          run_backed_decision_count: 9,
          success_count: 5,
          failure_count: 4,
          success_rate: 0.5556,
          lookback_days: 45,
          decision_types: { "queue_review_run" => 7 },
          actors: { "auto_review" => 9 },
          run_statuses: { "completed" => 5, "paused" => 4 },
          guardrail_violation_types: { "loop_detected" => 2 }
        },
        sample_successes: [ { id: 101 } ],
        sample_failures: [ { id: 202 } ]
      }
    end
    let(:mutation) do
      StrategyEvolution::Mutate::Mutation.new(
        configuration: strategy[:configuration].deep_dup,
        strategy: "risk_reduction",
        reasoning: "Reduce loop-prone retries",
        expected_improvement: "Fewer paused review runs",
        diff: [ { "path" => "/methods/paid_agent/termination/timeout_minutes", "from" => 30, "to" => 20 } ],
        provenance: { "source_version" => 3 }
      )
    end

    before do
      allow(StrategyEvolution::Mutate).to receive(:call).and_return([ mutation ])
    end

    it "adds reviewable provenance from the sampled history" do
      result = described_class.call(strategy: strategy, analysis: analysis, options: { mutation_count: 1 })

      expect(result.size).to eq(1)
      expect(result.first.provenance).to include(
        "generated_by" => "StrategyEvolution::GenerateCandidates",
        "sampled_decision_ids" => [ 101, 202 ]
      )
      expect(result.first.provenance.fetch("prior_versions")).to include(
        include(id: 12, version: 3, active: true)
      )
      expect(result.first.provenance.fetch("measured_outcomes")).to include(
        decision_count: 12,
        run_backed_decision_count: 9,
        failure_count: 4,
        success_rate: 0.5556,
        lookback_days: 45
      )
    end
  end
end
