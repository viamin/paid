# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::Optimizer, :no_db do
  let(:project) { Struct.new(:fitness_settings, :service_container_ids).new(nil, []) }
  let(:agent_run) do
    Struct.new(
      :id,
      :project,
      :project_id,
      :issue_id,
      :goal,
      :agent_type,
      :provider_id,
      :prompt_version_id,
      :custom_prompt,
      :model_selection,
      :service_container_ids,
      :mcp_server_snapshot,
      keyword_init: true
    ).new(
      id: 123,
      project: project,
      project_id: 456,
      issue_id: 789,
      goal: "create_pr",
      agent_type: "claude_code",
      provider_id: 12,
      prompt_version_id: 34,
      custom_prompt: nil,
      model_selection: nil,
      service_container_ids: [],
      mcp_server_snapshot: []
    )
  end
  let(:surrogate_model) do
    Class.new do
      def predict(...) = nil
    end.new
  end
  let(:optimizer) { described_class.new(agent_run: agent_run, surrogate_model: surrogate_model) }
  let(:experiment) { Struct.new(:id, :config_key).new(42, "knowledge.token_budget") }
  let(:control) { Struct.new(:id, :parsed_value).new(1, 4000) }
  let(:challenger) { Struct.new(:id, :parsed_value).new(2, 8000) }

  describe "#ranked_candidates" do
    before do
      allow(optimizer).to receive_messages(
        active_experiments: [ experiment ],
        active_experiment_variants_by_experiment_id: { experiment.id => [ control, challenger ] },
        prior_objective_score_for_goal: 0.8,
        prior_run_counts_for: [ 5, 1 ]
      )
    end

    it "exposes expected-improvement score inputs for ranked candidates" do
      allow(surrogate_model).to receive(:predict) { |bundle_definition:, **| prediction_for(bundle_definition) }

      ranked = optimizer.ranked_candidates

      expect(ranked.map { |selection| selection.score_inputs.acquisition_function }).to all(eq("expected_improvement"))
      expect(ranked.map { |selection| selection.score_inputs.best_observed_objective_score }).to all(eq(0.8))
      expect(ranked.first.variant_by_experiment_id).to eq(experiment.id => challenger)
      expect(ranked.first.score_inputs.acquisition_score).to be > ranked.last.score_inputs.acquisition_score
    end
  end

  describe "#outcome_objective_score" do
    it "reuses the canonical objective score extractor" do
      outcome = instance_double(Object)

      expect(ConfigurationBundles::ObjectiveScore).to receive(:from_outcome).with(outcome).and_return(0.84)

      expect(optimizer.send(:outcome_objective_score, outcome)).to eq(0.84)
    end
  end

  def prediction_for(bundle_definition)
    variant_id = bundle_definition.dig("experiments", experiment.config_key, "configuration_experiment_variant_id")
    return control_prediction if variant_id == control.id

    challenger_prediction
  end

  def control_prediction
    ConfigurationBundles::SurrogateModel::Prediction.new(
      mean_objective_score: 0.81,
      mean_quality_score: 0.81,
      uncertainty: 0.05,
      sample_count: 4,
      matched_outcomes: 4
    )
  end

  def challenger_prediction
    ConfigurationBundles::SurrogateModel::Prediction.new(
      mean_objective_score: 0.78,
      mean_quality_score: 0.78,
      uncertainty: 0.4,
      sample_count: 1,
      matched_outcomes: 1
    )
  end
end
