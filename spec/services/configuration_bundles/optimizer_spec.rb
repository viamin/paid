# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::Optimizer do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project, issue: create(:issue, project: project)) }
  let(:experiment) do
    create(:configuration_experiment,
      account: project.account,
      status: "running",
      config_key: "knowledge.token_budget",
      control_value: JSON.generate(4000))
  end
  let!(:control) do
    create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(4000),
      is_control: true)
  end
  let!(:challenger) do
    create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(8000))
  end

  describe ".call" do
    it "selects the candidate with the highest acquisition score" do
      create_bundle_history(
        experiment: experiment,
        variant: control,
        quality_scores: [ 0.72, 0.74, 0.76, 0.78 ]
      )
      create_bundle_history(
        experiment: experiment,
        variant: challenger,
        quality_scores: [ 0.9 ]
      )

      selection = described_class.call(agent_run: agent_run)

      expect(selection.variant_by_experiment_id).to eq(experiment.id => challenger)
      expect(selection.score_inputs.predicted_quality_score).to be > 0
      expect(selection.score_inputs.uncertainty).to be > 0
      expect(selection.score_inputs.acquisition_score).to be >
        selection.score_inputs.predicted_quality_score
    end

    it "returns nil when there are no active tracked experiments" do
      experiment.update!(status: "completed", completed_at: Time.current)

      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "learns from prior outcomes when an experiment is recreated with the same value" do
      create_prior_history
      experiment.update!(status: "completed", completed_at: Time.current)

      recreated_experiment, recreated_control, recreated_challenger = recreate_experiment

      selection = described_class.call(agent_run: agent_run)

      expect(selection.variant_by_experiment_id).to eq(recreated_experiment.id => recreated_challenger)
      expect(selection.definition.dig("experiments", experiment.config_key, "value")).to eq(8000)
      expect(selection.definition.dig("experiments", experiment.config_key, "configuration_experiment_variant_id")).to eq(recreated_challenger.id)
      expect(recreated_challenger.id).not_to eq(challenger.id)
      expect(recreated_control.id).not_to eq(control.id)
    end
  end

  def create_prior_history
    create_bundle_history(
      experiment: experiment,
      variant: control,
      quality_scores: [ 0.65, 0.67 ]
    )
    create_bundle_history(
      experiment: experiment,
      variant: challenger,
      quality_scores: [ 0.9, 0.92 ]
    )
  end

  def recreate_experiment
    recreated_experiment = create(:configuration_experiment,
      account: project.account,
      status: "running",
      config_key: experiment.config_key,
      control_value: JSON.generate(4000))
    recreated_control = create(:configuration_experiment_variant,
      configuration_experiment: recreated_experiment,
      config_value: JSON.generate(4000),
      is_control: true)
    recreated_challenger = create(:configuration_experiment_variant,
      configuration_experiment: recreated_experiment,
      config_value: JSON.generate(8000))

    [ recreated_experiment, recreated_control, recreated_challenger ]
  end

  def create_bundle_history(experiment:, variant:, quality_scores:)
    definition = {
      "schema_version" => 1,
      "goal" => agent_run.goal,
      "agent_type" => agent_run.agent_type,
      "provider_id" => agent_run.provider_id,
      "prompt_version_id" => agent_run.prompt_version_id,
      "experiments" => {
        experiment.config_key => {
          "configuration_experiment_id" => experiment.id,
          "configuration_experiment_variant_id" => variant.id,
          "value" => variant.parsed_value
        }
      }
    }
    bundle = create(:configuration_bundle, definition: definition)

    quality_scores.each do |quality_score|
      run = create(:agent_run, :completed, configuration_bundle: bundle, project: project, issue: create(:issue, project: project))
      create(:configuration_bundle_outcome,
        configuration_bundle: bundle,
        agent_run: run,
        quality_score: quality_score)
    end
  end
end
