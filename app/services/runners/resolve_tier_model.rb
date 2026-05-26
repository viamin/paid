# frozen_string_literal: true

module Runners
  class ResolveTierModel
    def self.call(...)
      new(...).call
    end

    def initialize(runner:, tier:, user: nil, provider: nil)
      @runner = runner
      @tier = tier.to_s
      @user = user
      @explicit_provider = provider
    end

    def call
      runner_entry = @runner&.tier_models&.dig(@tier)
      return success_result(runner_entry, source: "runner", fallback_provider_id: @runner&.id) if runner_entry.present?

      legacy_runner_id = @runner&.tier_model_ids&.dig(@tier)
      if legacy_runner_id.present?
        return Result.new(model_id: legacy_runner_id, provider_id: @runner.id, source: "runner")
      end

      provider = resolve_provider
      provider_entry = provider&.tier_models&.dig(@tier)
      return success_result(provider_entry, source: "provider", fallback_provider_id: provider&.id) if provider_entry.present?

      legacy_provider_id = provider&.tier_model_ids&.dig(@tier)
      if legacy_provider_id.present?
        return Result.new(model_id: legacy_provider_id, provider_id: provider.id, source: "provider")
      end

      default_model_id = DefaultTierModelIds.call(runner_key: @runner&.runner_key)[@tier]
      return failure_result("no model configured for #{@runner&.runner_key} at #{@tier}") if default_model_id.blank?

      Result.new(
        model_id: default_model_id,
        provider_id: provider&.id || @runner&.id,
        source: "default"
      )
    end

    private

    def resolve_provider
      @explicit_provider || @user&.provider_for(@runner)
    end

    def success_result(entry, source:, fallback_provider_id: nil)
      Result.new(
        model_id: entry.fetch("model_id"),
        provider_id: entry["provider_id"] || fallback_provider_id,
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
