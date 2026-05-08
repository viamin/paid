# frozen_string_literal: true

require "rails_helper"

RSpec.describe OutcomeOptimization::PredictBundlePerformance do
  describe ".call" do
    let(:bundle) do
      create(
        :configuration_bundle,
        orchestration_config: { "max_parallel_agents" => 1 },
        thresholds: { "quality_gate" => 0.7 }
      )
    end

    let(:better_bundle) do
      create(
        :configuration_bundle,
        account: bundle.account,
        orchestration_config: { "max_parallel_agents" => 4 },
        thresholds: { "quality_gate" => 0.9 }
      )
    end

    before do
      create(:bundle_outcome, configuration_bundle: bundle, outcome_score: 0.35, context_features: { "issue_complexity" => 0.2 })
      create(:bundle_outcome, configuration_bundle: bundle, outcome_score: 0.4, context_features: { "issue_complexity" => 0.3 })
      create(:bundle_outcome, configuration_bundle: better_bundle, outcome_score: 0.88, context_features: { "issue_complexity" => 0.8 })
      create(:bundle_outcome, configuration_bundle: better_bundle, outcome_score: 0.92, context_features: { "issue_complexity" => 0.9 })
    end

    it "returns optimizer-facing prediction outputs from stored bundle outcomes" do
      prediction = described_class.call(
        bundle: better_bundle,
        context_features: { "issue_complexity" => 0.85 },
        scope: BundleOutcome.for_training
      )

      expect(prediction.mean).to be_between(0.0, 1.0)
      expect(prediction.mean).to be > 0.7
      expect(prediction.uncertainty).to be_between(0.05, 1.0)
      expect(prediction.observation_count).to eq(2)
      expect(prediction.training_sample_count).to eq(4)
    end

    it "falls back to the default mean when no training data exists" do
      bundle = create(:configuration_bundle)

      prediction = described_class.call(bundle:, context_features: {}, scope: BundleOutcome.none)

      expect(prediction.mean).to eq(0.5)
      expect(prediction.observation_count).to eq(0)
      expect(prediction.training_sample_count).to eq(0)
    end
  end
end
