# frozen_string_literal: true

module OutcomeOptimization
  class FeatureExtractor
    def self.call(...)
      new(...).call
    end

    def initialize(bundle:, context_features:)
      @bundle = bundle
      @context_features = context_features || {}
    end

    def call
      {}.tap do |features|
        encode_categorical_map(features, "bundle.prompt_versions", bundle.prompt_versions)
        encode_categorical_map(features, "bundle.model_preferences", bundle.model_preferences)
        encode_value(features, "bundle.is_baseline", bundle.is_baseline)
        encode_value(features, "bundle.is_active", bundle.is_active)
        encode_value(features, "bundle.orchestration_config", bundle.orchestration_config)
        encode_value(features, "bundle.thresholds", bundle.thresholds)
        encode_value(features, "bundle.context_selector", bundle.context_selector)
        encode_value(features, "context", context_features)
      end
    end

    private

    attr_reader :bundle, :context_features

    def encode_categorical_map(features, prefix, values)
      values.to_h.stringify_keys.sort.each do |key, value|
        next if value.nil?

        features["#{prefix}.#{key}=#{token(value)}"] = 1.0
      end
    end

    def encode_value(features, prefix, value)
      case value
      when Hash
        value.stringify_keys.sort.each do |key, nested_value|
          encode_value(features, "#{prefix}.#{key}", nested_value)
        end
      when Array
        value.each_with_index do |nested_value, index|
          encode_value(features, "#{prefix}.#{index}", nested_value)
        end
      when true, false
        features[prefix] = value ? 1.0 : 0.0
      when Numeric
        features[prefix] = value.to_f
      when NilClass
        nil
      else
        features["#{prefix}=#{token(value)}"] = 1.0
      end
    end

    def token(value)
      value.to_s
    end
  end
end
