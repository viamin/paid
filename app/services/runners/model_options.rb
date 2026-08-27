# frozen_string_literal: true

module Runners
  class ModelOptions
    FREE_POLICY_OPTION = "__free_policy__"

    Result = Struct.new(:options, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(runner_key:, api_service_type:, auth_type: "api_key")
      @runner_key = runner_key.to_s
      @api_service_type = api_service_type.to_s
      @auth_type = auth_type.to_s
    end

    # @spec DIRECT-OUTBOUND-CATALOG-005
    def call
      Result.new(options: leading_options + catalog_options + [ custom_option ])
    end

    private

    attr_reader :runner_key, :api_service_type, :auth_type

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
      LlmModel.dropdown_options_for(api_service_type).select do |model|
        compatibility = Runners::ModelCompatibility.call(
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
