# frozen_string_literal: true

require "digest"

module ConfigurationBundles
  class Optimizer
    include BundleFingerprinting

    INVALID_VARIANT_VALUE = Object.new

    Selection = Struct.new(
      :definition,
      :fingerprint,
      :variant_by_experiment_id,
      :score_inputs,
      keyword_init: true
    )

    ScoreInputs = Struct.new(
      :predicted_quality_score,
      :uncertainty,
      :sample_count,
      :acquisition_score,
      keyword_init: true
    )

    EXPLORATION_WEIGHT = 0.4

    attr_reader :agent_run, :surrogate_model

    def initialize(agent_run:, surrogate_model: nil)
      @agent_run = agent_run
      @surrogate_model = surrogate_model || SurrogateModel.new(project: agent_run.project)
    end

    def self.call(...)
      new(...).select_bundle
    end

    def self.ranked_candidates(...)
      new(...).ranked_candidates
    end

    def select_bundle
      ranked_candidates.first
    end

    def ranked_candidates
      candidates = candidate_variants
      return [] if candidates.empty?

      candidates
        .map { |variant_by_experiment_id| score_candidate(variant_by_experiment_id) }
        .sort_by { |selection| -selection.score_inputs.acquisition_score }
    end

    private

    def score_candidate(variant_by_experiment_id)
      definition = bundle_definition(variant_by_experiment_id)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(definition))
      prediction = surrogate_model.predict(bundle_definition: definition, fingerprint: fingerprint)
      acquisition_score = prediction.mean_quality_score + (EXPLORATION_WEIGHT * prediction.uncertainty)

      Selection.new(
        definition: definition,
        fingerprint: fingerprint,
        variant_by_experiment_id: variant_by_experiment_id,
        score_inputs: ScoreInputs.new(
          predicted_quality_score: prediction.mean_quality_score,
          uncertainty: prediction.uncertainty,
          sample_count: prediction.sample_count,
          acquisition_score: acquisition_score
        )
      )
    end

    def candidate_variants
      experiments = active_experiments.filter_map do |experiment|
        variants = active_experiment_variants_by_experiment_id.fetch(experiment.id, []).filter_map do |variant|
          next if parsed_variant_value(variant, experiment:).equal?(INVALID_VARIANT_VALUE)

          [ experiment.id, variant ]
        end
        next if variants.empty?

        variants
      end
      return [] if experiments.empty?

      experiments.shift.product(*experiments).map do |combination|
        Array(combination).flatten(1).each_slice(2).to_h
      end
    end

    def active_experiments
      @active_experiments ||= ConfigurationExperiment::TRACKED_CONFIG_KEYS.filter_map do |config_key|
        ConfigurationExperiment.active_for(config_key, project: agent_run.project, agent_run: agent_run)
      end
    end

    def active_experiment_variants_by_experiment_id
      @active_experiment_variants_by_experiment_id ||= ConfigurationExperimentVariant
        .where(configuration_experiment_id: active_experiments.map(&:id))
        .order(:configuration_experiment_id, :id)
        .to_a
        .group_by(&:configuration_experiment_id)
    end

    def bundle_definition(variant_by_experiment_id)
      canonicalize(
        {
          schema_version: 1,
          goal: agent_run.goal,
          agent_type: agent_run.agent_type,
          provider_id: agent_run.provider_id,
          prompt_version_id: agent_run.prompt_version_id,
          custom_prompt_sha256: custom_prompt_sha256,
          model_selection: model_selection_definition,
          service_container_ids: normalized_service_container_ids,
          mcp_servers: normalized_mcp_servers,
          experiments: experiment_definitions(variant_by_experiment_id)
        }.compact
      )
    end

    def experiment_definitions(variant_by_experiment_id)
      variant_by_experiment_id.each_with_object({}) do |(_, variant), definitions|
        experiment = variant.configuration_experiment
        definitions[experiment.config_key] = {
          configuration_experiment_id: experiment.id,
          configuration_experiment_variant_id: variant.id,
          value: parsed_variant_value(variant, experiment:)
        }
      end
    end

    def parsed_variant_value(variant, experiment:)
      @parsed_variant_values ||= {}
      return @parsed_variant_values[variant.id] if @parsed_variant_values.key?(variant.id)

      @parsed_variant_values[variant.id] = variant.parsed_value
    rescue StandardError => e
      Rails.logger.warn(
        message: "configuration_bundles.invalid_optimizer_variant_skipped",
        agent_run_id: agent_run.id,
        configuration_experiment_id: experiment.id,
        configuration_experiment_variant_id: variant.id,
        error_class: e.class.name,
        error: e.message
      )

      @parsed_variant_values[variant.id] = INVALID_VARIANT_VALUE
    end
  end
end
