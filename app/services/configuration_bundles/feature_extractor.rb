# frozen_string_literal: true

module ConfigurationBundles
  class FeatureExtractor
    include Canonicalization

    FeatureVector = Struct.new(
      :goal,
      :agent_type,
      :provider_id,
      :prompt_version_id,
      :custom_prompt_sha256,
      :model_selection,
      :has_model_selection,
      :has_custom_prompt,
      :has_mcp_servers,
      :service_container_ids,
      :mcp_servers,
      :service_container_count,
      :mcp_server_count,
      :experiment_features,
      keyword_init: true
    )

    def self.call(bundle_definition)
      new.extract(bundle_definition)
    end

    def extract(definition)
      mcp_servers = normalized_mcp_servers(definition)

      FeatureVector.new(
        goal: definition["goal"],
        agent_type: definition["agent_type"],
        provider_id: definition["provider_id"],
        prompt_version_id: definition["prompt_version_id"],
        custom_prompt_sha256: definition["custom_prompt_sha256"],
        model_selection: canonicalize(definition["model_selection"]),
        has_model_selection: definition["model_selection"].present?,
        has_custom_prompt: definition["custom_prompt_sha256"].present?,
        has_mcp_servers: mcp_servers.any?,
        service_container_ids: Array(definition["service_container_ids"]).sort,
        mcp_servers: mcp_servers,
        service_container_count: Array(definition["service_container_ids"]).size,
        mcp_server_count: mcp_servers.size,
        experiment_features: extract_experiment_features(definition)
      )
    end

    private

    def extract_experiment_features(definition)
      experiments = definition.fetch("experiments", {})
      return {} unless experiments.is_a?(Hash)

      experiments.each_with_object({}) do |(key, value), features|
        features[key.to_s] = experiment_feature_value(value)
      end
    end

    def experiment_feature_value(value)
      raw = if value.is_a?(Hash)
        value.key?("value") ? value["value"] : value["configuration_experiment_variant_id"]
      else
        value
      end

      normalize_experiment_value(raw)
    end

    def normalize_experiment_value(value)
      case value
      when Numeric
        value.to_f
      when String
        Float(value, exception: false) || value
      when TrueClass, FalseClass, NilClass
        value
      when Array, Hash
        JSON.generate(sort_nested_structure(value))
      else
        Float(value, exception: false) || value.to_s
      end
    end

    def sort_nested_structure(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) do |key, normalized|
          normalized[key] = sort_nested_structure(value[key])
        end
      when Array
        value.map { |item| sort_nested_structure(item) }
      else
        value
      end
    end
  end
end
