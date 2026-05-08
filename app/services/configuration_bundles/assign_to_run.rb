# frozen_string_literal: true

require "digest"

module ConfigurationBundles
  class AssignToRun
    attr_reader :agent_run

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).call
    end

    def call
      definition = bundle_definition
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(definition))

      bundle = find_or_create_bundle(fingerprint:, definition:)
      agent_run.update!(configuration_bundle: bundle) unless agent_run.configuration_bundle_id == bundle.id
      bundle
    end

    private

    def find_or_create_bundle(fingerprint:, definition:)
      ConfigurationBundle.find_or_create_by!(fingerprint: fingerprint) do |bundle|
        bundle.definition = definition
      end
    rescue ActiveRecord::RecordNotUnique
      ConfigurationBundle.find_by!(fingerprint: fingerprint)
    end

    def bundle_definition
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
          experiments: experiment_definitions
        }.compact
      )
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

    def experiment_definitions
      ConfigurationExperiment::TRACKED_CONFIG_KEYS.each_with_object({}) do |config_key, definitions|
        experiment = ConfigurationExperiment.active_for(config_key, project: agent_run.project, agent_run: agent_run)
        next unless experiment

        assignment = ConfigurationExperiments::Assign.call(
          configuration_experiment: experiment,
          agent_run: agent_run
        )
        definitions[config_key] = {
          configuration_experiment_id: experiment.id,
          configuration_experiment_variant_id: assignment.configuration_experiment_variant_id,
          value: assignment.configuration_experiment_variant.parsed_value
        }
      end
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
