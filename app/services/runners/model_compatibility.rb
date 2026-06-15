# frozen_string_literal: true

module Runners
  # Paid-side wrapper around the agent-harness model compatibility contract.
  #
  # Checks whether a given (runner_key, model_id, auth_type) combination can
  # actually execute on the installed runner CLI. This is the single integration
  # point for compatibility facts sourced from agent-harness.
  #
  # When viamin/agent-harness#259 lands and exposes a structured compatibility
  # API such as `AgentHarness.provider(key).model_compatibility(...)`, this
  # service will delegate to it. Until then, known constraints are encoded as
  # static contracts here.
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
      provider_mismatch
      subscription_only
    ].freeze

    # Models that the current Codex CLI pin (agent-harness 0.22.5) cannot
    # execute regardless of auth type. These require a newer Codex CLI.
    # When the Gemfile bumps agent-harness past the release that ships a
    # compatible Codex CLI, remove the relevant entry here and rely on the
    # harness compatibility API instead.
    # See: TODO(#2566) in Gemfile and seed_known_models.rb.
    CODEX_CLI_VERSION_GATED_MODELS = %w[
      gpt-5.5
      gpt-5.5-pro
    ].freeze

    def self.call(runner_key:, model_id:, auth_type:)
      new(runner_key: runner_key, model_id: model_id, auth_type: auth_type).call
    end

    def initialize(runner_key:, model_id:, auth_type:)
      @runner_key = runner_key.to_s
      @model_id = model_id.to_s
      @auth_type = auth_type.to_s
    end

    def call
      # Delegate to agent-harness when it exposes the compatibility API
      # (viamin/agent-harness#259). The guard is safe to remove once the
      # harness version in Gemfile.lock includes model_compatibility.
      if harness_provider_supports_compat_api?
        return harness_compat_result
      end

      internal_compat_check
    end

    private

    attr_reader :runner_key, :model_id, :auth_type

    # ---------------------------------------------------------------------------
    # agent-harness delegation
    # ---------------------------------------------------------------------------

    def harness_provider_supports_compat_api?
      klass = AgentHarness.provider_class(harness_key)
      klass.respond_to?(:model_compatibility)
    rescue AgentHarness::ConfigurationError, NameError, KeyError
      false
    end

    def harness_compat_result
      klass = AgentHarness.provider_class(harness_key)
      raw = klass.model_compatibility(
        model_id: model_id,
        auth_type: auth_type.to_sym
      )
      Result.new(
        supported: raw[:supported],
        reason: raw[:reason],
        incompatibility_type: raw[:incompatibility_type]&.to_sym,
        replacement_model_id: raw[:replacement_model_id],
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

    # ---------------------------------------------------------------------------
    # Internal static contracts
    # ---------------------------------------------------------------------------

    def internal_compat_check
      case runner_key
      when "codex"
        codex_check
      else
        standard_provider_check
      end
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

      model = LlmModel.find_by(model_id: model_id)

      # Any model that isn't OpenAI-provider is clearly wrong for Codex.
      if model && model.provider != "openai"
        return Result.new(
          supported: false,
          reason: "'#{model_id}' belongs to provider '#{model.provider}', not 'openai' (required for Codex)",
          incompatibility_type: :provider_mismatch,
          replacement_model_id: nil,
          source: "paid_catalog"
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

      if model.provider != expected_provider
        return Result.new(
          supported: false,
          reason: "'#{model_id}' belongs to provider '#{model.provider}', not '#{expected_provider}' (required for #{runner_key})",
          incompatibility_type: :provider_mismatch,
          replacement_model_id: nil,
          source: "paid_catalog"
        )
      end

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
