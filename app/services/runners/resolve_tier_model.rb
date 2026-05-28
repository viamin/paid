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
      return success_result(runner_entry, source: "runner") if runner_entry.present?

      provider_entry = provider&.tier_models&.dig(tier)
      return success_result(provider_entry, source: "provider") if provider_entry.present?

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
