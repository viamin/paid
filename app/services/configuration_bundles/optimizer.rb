# frozen_string_literal: true

require "digest"

module ConfigurationBundles
  class Optimizer
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

    def select_bundle
      candidates = candidate_variants
      return if candidates.empty?

      candidates
        .map { |variant_by_experiment_id| score_candidate(variant_by_experiment_id) }
        .max_by { |selection| selection.score_inputs.acquisition_score }
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
      experiments = active_experiments
      return [] if experiments.empty?

      combinations = experiments.map do |experiment|
        experiment.configuration_experiment_variants.order(:id).map { |variant| [ experiment.id, variant ] }
      end

      combinations.shift.product(*combinations).map do |combination|
        Array(combination).flatten(1).each_slice(2).to_h
      end
    end

    def active_experiments
      ConfigurationExperiment::TRACKED_CONFIG_KEYS.filter_map do |config_key|
        ConfigurationExperiment.active_for(config_key, project: agent_run.project, agent_run: agent_run)
      end
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
          value: variant.parsed_value
        }
      end
    end

    def custom_prompt_sha256
      return if agent_run.custom_prompt.blank?

      Digest::SHA256.hexdigest(agent_run.custom_prompt)
    end

    def normalized_service_container_ids
      ids = Array(agent_run.service_container_ids).map { |id| Integer(id, exception: false) || id }.compact.sort
      ids if ids.any?
    end

    def normalized_mcp_servers
      servers = Array(agent_run.mcp_server_snapshot).filter_map { |snapshot| snapshot["name"].presence }.sort
      servers if servers.any?
    end

    def canonicalize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested_value), normalized|
          normalized[key.to_s] = canonicalize(nested_value)
        end.sort.to_h
      when Array
        value.map { |nested_value| canonicalize(nested_value) }
      else
        value
      end
    end
  end
end
