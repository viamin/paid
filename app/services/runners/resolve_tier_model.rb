# frozen_string_literal: true

module Runners
  class ResolveTierModel
    def self.call(...)
      new(...).call
    end

    def initialize(runner:, tier:, user:)
      @runner = runner
      @tier = tier.to_s
      @user = user
    end

    def call
      provider = user&.provider_for(runner)

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
      resolve_tier_models_entry(runner.tier_models[tier], source: "runner") ||
        resolve_tier_models_entry(provider&.tier_models&.dig(tier), source: "provider") ||
        resolve_tier_model_id(runner.tier_model_ids&.dig(tier), provider_id: provider&.id, source: "runner") ||
        resolve_tier_model_id(provider&.tier_model_ids&.dig(tier), provider_id: provider&.id, source: "provider") ||
        resolve_default(provider)
    end

    private

    attr_reader :runner, :tier, :user

    def resolve_tier_models_entry(entry, source:)
      return nil if entry.blank?

      resolve_candidate(
        model_id: entry.fetch("model_id"),
        provider_id: entry["provider_id"],
        source: source
      )
    end

    def resolve_tier_model_id(model_id, provider_id:, source:)
      return nil if model_id.blank?

      resolve_candidate(model_id: model_id, provider_id: provider_id, source: source)
    end

    def resolve_candidate(model_id:, provider_id:, source:)
      compat = compatibility_for(model_id)
      log_incompatibility_if_unsupported(compat, model_id: model_id, source: source)
      return failure_result(incompatibility_message(model_id, compat)) if compat.unsupported?

      Result.new(model_id: model_id, provider_id: provider_id, source: source)
    end

    def resolve_default(provider)
      default_model_id = DefaultTierModelIds.call(
        runner_key: runner.runner_key,
        auth_type: runner.auth_type
      )[tier]
      return failure_result("no model configured for #{runner.runner_key} at #{tier}") if default_model_id.blank?

      Result.new(
        model_id: default_model_id,
        provider_id: provider&.id,
        source: "default"
      )
    end

    def compatibility_for(model_id)
      ModelCompatibility.call(
        runner_key: runner.runner_key,
        model_id: model_id,
        auth_type: runner.auth_type
      )
    end

    def log_incompatibility_if_unsupported(compat, model_id:, source:)
      return unless compat.unsupported?

      Rails.logger.warn(
        message: "model_selection.incompatible_model_candidate",
        runner_key: runner.runner_key,
        runner_id: runner.id,
        model_id: model_id,
        auth_type: runner.auth_type,
        tier: tier,
        source: source,
        incompatibility_type: compat.incompatibility_type,
        reason: compat.reason,
        replacement_model_id: compat.replacement_model_id
      )
    end

    def incompatibility_message(model_id, compat)
      base = "model '#{model_id}' is not compatible with runner '#{runner.runner_key}' at tier '#{tier}'"
      compat.reason.present? ? "#{base}: #{compat.reason}" : base
    end

    def failure_result(error)
      Result.new(error: error)
    end

    class Result
      attr_reader :model_id, :provider_id, :source, :error

      def initialize(model_id: nil, provider_id: nil, source: nil, error: nil)
        @model_id = model_id
        @provider_id = provider_id
        @source = source
        @error = error
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
