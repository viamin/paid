# frozen_string_literal: true

module Runners
  # Paid-side wrapper around the agent-harness model compatibility contract.
  #
  # Checks whether a given (runner_key, model_id, auth_type) combination can
  # actually execute on the installed runner CLI. This is the single integration
  # point for compatibility facts sourced from agent-harness.
  #
  # Callers should treat +supported: nil+ (unknown) as permissive — do not
  # reject a model merely because compatibility cannot be asserted statically.
  class ModelCompatibility
    # Structured compatibility result.
    Result = Struct.new(
      :supported,           # true = compatible, false = incompatible, nil = unknown
      :reason,              # Human-readable reason for incompatibility, or nil
      :incompatibility_type, # Symbol or nil — see INCOMPATIBILITY_TYPES
      :replacement_model_id, # Model ID that could be used instead, or nil
      :source,              # String describing what produced this result
      keyword_init: true
    ) do
      def supported? = supported == true
      def unsupported? = supported == false
      def unknown? = supported.nil?
    end

    INCOMPATIBILITY_TYPES = %i[
      model_not_found
      cli_version_gated
      auth_unknown
      auth_mode_gated_for_model
      provider_mismatch
      subscription_only
    ].freeze

    # Legacy fallback only used if agent-harness is too old to expose its
    # compatibility contract. Once Paid only supports harness versions with the
    # contract, this can be removed.
    CODEX_CLI_VERSION_GATED_MODELS = %w[
      gpt-5.5
      gpt-5.5-pro
    ].freeze

    def self.call(runner_key:, model_id:, auth_type:, provider_runtime: nil)
      new(
        runner_key: runner_key,
        model_id: model_id,
        auth_type: auth_type,
        provider_runtime: provider_runtime
      ).call
    end

    def initialize(runner_key:, model_id:, auth_type:, provider_runtime: nil)
      @runner_key = runner_key.to_s
      @model_id = model_id.to_s
      @auth_type = auth_type.to_s
      @provider_runtime = provider_runtime
    end

    def call
      internal_compat_check
    end

    private

    attr_reader :runner_key, :model_id, :auth_type, :provider_runtime

    # ---------------------------------------------------------------------------
    # agent-harness delegation
    # ---------------------------------------------------------------------------

    def harness_provider_supports_compat_api?
      AgentHarness.respond_to?(:model_compatibility)
    rescue NameError
      false
    end

    def harness_compat_result
      raw = AgentHarness.model_compatibility(
        runner: harness_key,
        model_id: model_id,
        auth_mode: auth_type_symbol,
        cli_version: harness_cli_version
      )

      Result.new(
        supported: raw.supported,
        reason: human_reason_for(raw),
        incompatibility_type: incompatibility_type_for(raw),
        replacement_model_id: raw.fallback_model_id,
        source: "agent_harness"
      )
    rescue => e
      Rails.logger.warn(
        message: "model_selection.harness_compat_check_failed",
        runner_key: runner_key,
        model_id: model_id,
        auth_type: auth_type,
        error: e.message
      )
      unknown_result("agent_harness_error")
    end

    def harness_key
      RunnerSupport.harness_runner_key_for(runner_key).to_sym
    end

    def auth_type_symbol
      auth_type.presence&.to_sym
    end

    def harness_cli_version
      AgentHarness.provider_metadata(harness_key)
        .dig(:runtime, :installation, :resolved_version)
    rescue AgentHarness::ConfigurationError, KeyError
      nil
    end

    def incompatibility_type_for(raw)
      return :cli_version_gated if raw.reason == AgentHarness::ModelCompatibility::UNSUPPORTED_CLI_VERSION_REASON
      return :auth_unknown if raw.reason == AgentHarness::ModelCompatibility::UNSUPPORTED_AUTH_MODE_REASON
      return :auth_mode_gated_for_model if raw.reason == AgentHarness::ModelCompatibility::UNSUPPORTED_AUTH_MODE_FOR_MODEL_REASON

      nil
    end

    def human_reason_for(raw)
      case raw.reason
      when AgentHarness::ModelCompatibility::UNSUPPORTED_CLI_VERSION_REASON
        requirement = raw.cli_version_requirement || raw.minimum_cli_version
        "'#{model_id}' requires Codex CLI #{requirement}"
      when AgentHarness::ModelCompatibility::UNSUPPORTED_AUTH_MODE_REASON
        "'#{model_id}' does not support auth mode '#{auth_type}' for #{runner_key}"
      when AgentHarness::ModelCompatibility::UNSUPPORTED_AUTH_MODE_FOR_MODEL_REASON
        supported_modes = raw.details&.dig(:supported_auth_modes)
        if supported_modes.present?
          "'#{model_id}' is not available under auth mode '#{auth_type}' (supported: #{supported_modes.join(', ')})"
        else
          "'#{model_id}' is not available under auth mode '#{auth_type}'"
        end
      else
        nil
      end
    end

    # ---------------------------------------------------------------------------
    # Internal static contracts
    # ---------------------------------------------------------------------------

    def internal_compat_check
      catalog_result = catalog_provider_check
      return catalog_result if catalog_result

      return harness_compat_result if harness_provider_supports_compat_api?

      case runner_key
      when "codex"
        codex_check
      else
        standard_provider_check
      end
    end

    def catalog_provider_check
      expected_provider = Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner_key]
      return if expected_provider.blank?

      model = LlmModel.find_by(model_id: model_id)
      return if model.blank?

      return if model.provider == expected_provider

      Result.new(
        supported: false,
        reason: "'#{model_id}' belongs to provider '#{model.provider}', not '#{expected_provider}' (required for #{runner_key})",
        incompatibility_type: :provider_mismatch,
        replacement_model_id: nil,
        source: "paid_catalog"
      )
    end

    def codex_check
      if CODEX_CLI_VERSION_GATED_MODELS.include?(model_id)
        return Result.new(
          supported: false,
          reason: "'#{model_id}' requires a newer version of the Codex CLI than the installed agent-harness version supports",
          incompatibility_type: :cli_version_gated,
          replacement_model_id: nil,
          source: "paid_static_contract"
        )
      end

      # Subscription auth has access to whatever the Codex subscription grants;
      # api_key auth has access to whatever the key's account entitles. Paid
      # cannot statically enumerate all entitlements, so once we've cleared the
      # CLI-version gate, the result is unknown unless agent-harness provides
      # richer data.
      unknown_result("paid_static_contract")
    end

    def standard_provider_check
      expected_provider = Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner_key]
      return unknown_result("paid_static_contract") if expected_provider.blank?

      model = LlmModel.find_by(model_id: model_id)
      return unknown_result("paid_catalog") if model.blank?

      unknown_result("paid_catalog")
    end

    def unknown_result(source)
      Result.new(
        supported: nil,
        reason: nil,
        incompatibility_type: nil,
        replacement_model_id: nil,
        source: source
      )
    end
  end
end
