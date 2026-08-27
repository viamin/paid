# frozen_string_literal: true

module Runners
  class ModelOptions
    FREE_POLICY_OPTION = "__free_policy__"

    Result = Struct.new(:options, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    # catalog_cache/compatibility_cache let callers that build option maps
    # across many (runner_key, api_service_type) pairs in one request (e.g.
    # the runner form) reuse catalog queries and compatibility checks instead
    # of repeating them once per pair. Callers computing a single map (e.g. a
    # form's initial render) can omit them and get a fresh, per-call cache.
    def initialize(runner_key:, api_service_type:, auth_type: "api_key", catalog_cache: {}, compatibility_cache: {})
      @runner_key = runner_key.to_s
      @api_service_type = api_service_type.to_s
      @auth_type = auth_type.to_s
      @catalog_cache = catalog_cache
      @compatibility_cache = compatibility_cache
    end

    # @spec DIRECT-OUTBOUND-CATALOG-005
    def call
      Result.new(options: leading_options + catalog_options + [ custom_option ])
    end

    private

    attr_reader :runner_key, :api_service_type, :auth_type, :catalog_cache, :compatibility_cache

    def leading_options
      options = []
      options << free_policy_option if free_policy_supported?
      options
    end

    def catalog_options
      compatible_models.map do |model|
        {
          value: model.model_id,
          label: model.display_name,
          family: model.family.presence || "Other",
          kind: "catalog"
        }
      end
    end

    def compatible_models
      catalog = catalog_cache[api_service_type] ||= LlmModel.dropdown_options_for(api_service_type).to_a

      catalog.select do |model|
        compatibility = compatibility_cache[[ runner_key, model.model_id, auth_type ]] ||= Runners::ModelCompatibility.call(
          runner_key: runner_key,
          model_id: model.model_id,
          auth_type: auth_type
        )
        !compatibility.unsupported?
      end
    end

    def free_policy_supported?
      runner_key == "opencode" && api_service_type == "openrouter"
    end

    def free_policy_option
      {
        value: FREE_POLICY_OPTION,
        label: "OpenRouter Free (curated, tiered)",
        family: nil,
        kind: "free_policy"
      }
    end

    def custom_option
      {
        value: LlmModel::CUSTOM_MODEL_OPTION,
        label: "Custom model ID…",
        family: nil,
        kind: "custom"
      }
    end
  end
end
