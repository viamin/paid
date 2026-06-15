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
      runner_entry = runner.tier_models[tier]
      if runner_entry.present?
        model_id = runner_entry.fetch("model_id")
        check_and_log_compatibility(model_id, source: "runner")
        compat = compatibility_for(model_id)
        if compat.unsupported?
          return failure_result(incompatibility_message(model_id, compat))
        end

        return success_result(runner_entry, source: "runner")
      end

      provider_entry = provider&.tier_models&.dig(tier)
      if provider_entry.present?
        model_id = provider_entry.fetch("model_id")
        check_and_log_compatibility(model_id, source: "provider")
        compat = compatibility_for(model_id)
        if compat.unsupported?
          return failure_result(incompatibility_message(model_id, compat))
        end

        return success_result(provider_entry, source: "provider")
      end

      default_model_id = DefaultTierModelIds.call(runner_key: runner.runner_key)[tier]
      return failure_result("no model configured for #{runner.runner_key} at #{tier}") if default_model_id.blank?

      Result.new(
        model_id: default_model_id,
        provider_id: provider&.id,
        source: "default"
      )
    end

    private

    attr_reader :runner, :tier, :user

    def compatibility_for(model_id)
      ModelCompatibility.call(
        runner_key: runner.runner_key,
        model_id: model_id,
        auth_type: runner.auth_type
      )
    end

    def check_and_log_compatibility(model_id, source:)
      compat = compatibility_for(model_id)
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

    def success_result(entry, source:)
      Result.new(
        model_id: entry.fetch("model_id"),
        provider_id: entry.fetch("provider_id"),
        source: source
      )
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
