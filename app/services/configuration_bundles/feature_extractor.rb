# frozen_string_literal: true

module ConfigurationBundles
  class FeatureExtractor
    include Canonicalization

    FeatureVector = Struct.new(
      :goal,
      :agent_type,
      :has_model_selection,
      :has_custom_prompt,
      :has_mcp_servers,
      :service_container_count,
      :mcp_server_count,
      :experiment_features,
      keyword_init: true
    )

    def self.call(bundle_definition)
      new.extract(bundle_definition)
    end

    def extract(definition)
      FeatureVector.new(
        goal: definition["goal"],
        agent_type: definition["agent_type"],
        has_model_selection: definition["model_selection"].present?,
        has_custom_prompt: definition["custom_prompt_sha256"].present?,
        has_mcp_servers: Array(definition["mcp_servers"]).any?,
        service_container_count: Array(definition["service_container_ids"]).size,
        mcp_server_count: Array(definition["mcp_servers"]).size,
        experiment_features: extract_experiment_features(definition)
      )
    end

    private

    def extract_experiment_features(definition)
      definition.fetch("experiments", {}).each_with_object({}) do |(key, value), features|
        features[key] = numeric_experiment_value(value)
      end
    end

    def numeric_experiment_value(value)
      case value
      when Hash
        raw = value.key?("value") ? value["value"] : value["configuration_experiment_variant_id"]
        Float(raw, exception: false) || 0.0
      when Numeric
        value.to_f
      else
        Float(value, exception: false) || 0.0
      end
    end
  end
end
