# frozen_string_literal: true

module Runners
  # @spec RUNNER-FALLBACK-001, RUNNER-FALLBACK-002
  class ResolveTierModel
    def self.call(...)
      new(...).call
    end

    def initialize(runner:, tier:, user:, project: nil, goal: nil)
      @runner = runner
      @tier = tier.to_s
      @user = user
      @project = project
      @goal = goal
    end

    def call
      provider = user&.provider_for(runner)
      auth_type = effective_auth_type_for(provider)
      recovered = VerifiedModels.new(runner.persisted? ? runner : provider).model_for(tier, project: @project, goal: @goal) if runner.persisted? || provider
      return Result.new(model_id: recovered, provider_id: provider&.id, source: "verified_recovery") if recovered

      # Resolve, in priority order:
      #   1. runner.tier_models   — structured tier→{model_id, provider_id}
      #   2. provider.tier_models — same shape on the user's provider entry
      #   3. runner.tier_model_ids / provider.tier_model_ids — the only tier→model
      #      column the admin UI writes. Must be honored for ALL runner types,
      #      not just direct-outbound runners whose tier_models was backfilled,
      #      otherwise admin edits are silently ignored and resolution drifts to
      #      the capability_score default (#2968).
      #   4. DefaultTierModelIds — highest capability_score in the LlmModel
      #      catalog, gated by the runner's actual auth_type.
      resolve_tier_models_entry(runner.tier_models[tier], source: "runner", auth_type: auth_type) ||
        resolve_tier_models_entry(provider&.tier_models&.dig(tier), source: "provider", auth_type: auth_type) ||
        resolve_tier_model_id(runner.tier_model_ids&.dig(tier), provider_id: provider&.id, source: "runner", auth_type: auth_type) ||
        resolve_tier_model_id(provider&.tier_model_ids&.dig(tier), provider_id: provider&.id, source: "provider", auth_type: auth_type) ||
        resolve_default(provider, auth_type: auth_type)
    end

    private

    attr_reader :runner, :tier, :user

    def resolve_tier_models_entry(entry, source:, auth_type:)
      return nil if entry.blank?

      resolve_candidate(
        model_id: entry.fetch("model_id"),
        provider_id: entry["provider_id"],
        source: source,
        auth_type: auth_type
      )
    end

    def resolve_tier_model_id(model_id, provider_id:, source:, auth_type:)
      return nil if model_id.blank?

      resolve_candidate(model_id: model_id, provider_id: provider_id, source: source, auth_type: auth_type)
    end

    def resolve_candidate(model_id:, provider_id:, source:, auth_type:)
      compat = compatibility_for(model_id, auth_type: auth_type)
      log_incompatibility_if_unsupported(compat, model_id: model_id, source: source, auth_type: auth_type)
      if compat.unsupported? && !live_auth_verification?(compat, auth_type)
        return failure_result(incompatibility_message(model_id, compat))
      end

      evidence = VerifiedModels.new(runner)
      if @project && !evidence.permitted?(model_id, project: @project, goal: @goal) &&
          DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER.key?(runner.runner_key)
        return failure_result("model '#{model_id}' violates project model policy or operator policy", error_type: :policy)
      end

      Result.new(model_id: model_id, provider_id: provider_id, source: source)
    end

    def resolve_default(provider, auth_type:)
      default_model_id = DefaultTierModelIds.call(
        runner_key: runner.runner_key,
        auth_type: auth_type
      )[tier]
      return failure_result("no model configured for #{runner.runner_key} at #{tier}") if default_model_id.blank?

      Result.new(
        model_id: default_model_id,
        provider_id: provider&.id,
        source: "default"
      )
    end

    def compatibility_for(model_id, auth_type:)
      ModelCompatibility.call(
        runner_key: runner.runner_key,
        model_id: model_id,
        auth_type: auth_type
      )
    end

    # Account entitlements are established by the runner's actual preflight,
    # not a static provider-wide auth restriction that may have gone stale.
    def live_auth_verification?(compat, auth_type)
      return false unless auth_type == "subscription" && compat.incompatibility_type == :auth_mode_gated_for_model

      key = RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym
      AgentHarness.provider_class(key).method_defined?(:discover_available_models)
    end

    def log_incompatibility_if_unsupported(compat, model_id:, source:, auth_type:)
      return unless compat.unsupported?

      Rails.logger.warn(
        message: "model_selection.incompatible_model_candidate",
        runner_key: runner.runner_key,
        runner_id: runner.id,
        model_id: model_id,
        auth_type: auth_type,
        tier: tier,
        source: source,
        incompatibility_type: compat.incompatibility_type,
        reason: compat.reason,
        replacement_model_id: compat.replacement_model_id
      )
    end

    def effective_auth_type_for(provider)
      provider&.auth_type.presence || runner.auth_type.to_s.presence || DefaultTierModelIds::DEFAULT_AUTH_TYPE
    end

    def incompatibility_message(model_id, compat)
      base = "model '#{model_id}' is not compatible with runner '#{runner.runner_key}' at tier '#{tier}'"
      compat.reason.present? ? "#{base}: #{compat.reason}" : base
    end

    def failure_result(error, error_type: nil)
      Result.new(error: error, error_type: error_type)
    end

    class Result
      attr_reader :model_id, :provider_id, :source, :error, :error_type

      def initialize(model_id: nil, provider_id: nil, source: nil, error: nil, error_type: nil)
        @model_id = model_id
        @provider_id = provider_id
        @source = source
        @error = error
        @error_type = error_type
      end

      def success?
        error.blank?
      end

      def failure?
        !success?
      end
    end
  end
end
