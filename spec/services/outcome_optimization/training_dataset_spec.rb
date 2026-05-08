# frozen_string_literal: true

require "rails_helper"

RSpec.describe OutcomeOptimization::TrainingDataset do
  describe ".call" do
    let(:bundle) do
      create(
        :configuration_bundle,
        prompt_versions: { "planning" => 11, "coding" => 22 },
        model_preferences: { "planning" => "gpt-5.4", "coding" => "codex" },
        orchestration_config: { "max_parallel_agents" => 3, "allow_retry" => true },
        thresholds: { "quality_gate" => 0.85 }
      )
    end

    let(:outcome) do
      create(
        :bundle_outcome,
        configuration_bundle: bundle,
        context_features: { "project_language" => "ruby", "issue_complexity" => 0.7 },
        outcome_score: 0.91
      )
    end

    it "builds training rows from bundles and outcomes with flattened features" do
      dataset = described_class.call(scope: BundleOutcome.where(id: outcome.id).includes(:configuration_bundle))

      expect(dataset.sample_count).to eq(1)
      expect(dataset.feature_names).to include(
        "bundle.prompt_versions.planning=11",
        "bundle.model_preferences.coding=codex",
        "bundle.orchestration_config.max_parallel_agents",
        "bundle.orchestration_config.allow_retry",
        "bundle.thresholds.quality_gate",
        "context.project_language=ruby",
        "context.issue_complexity"
      )
      expect(dataset.rows.first).to have_attributes(
        bundle_outcome_id: outcome.id,
        configuration_bundle_id: bundle.id,
        agent_run_id: outcome.agent_run_id,
        outcome_score: 0.91
      )
    end
  end
end
