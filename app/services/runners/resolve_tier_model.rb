# frozen_string_literal: true

module Runners
  class ResolveTierModel
    Result = Data.define(:model_id, :provider_id, :source, :error) do
      def success?
        error.nil?
      end

      def failure?
        !success?
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(runner:, tier:, provider: nil)
      @runner = runner
      @tier = tier.to_s
      @provider = provider
    end

    def call
      runner_entry = @runner&.tier_models&.dig(@tier)
      return success_from(entry: runner_entry, source: "runner") if runner_entry.present?

      provider_entry = @provider&.tier_models&.dig(@tier)
      return success_from(entry: provider_entry, source: "provider") if provider_entry.present?

      default_model_id = Runners::DefaultTierModelIds.call(runner_key: @runner&.runner_key)[@tier]
      if default_model_id.blank?
        return Result.new(
          model_id: nil,
          provider_id: nil,
          source: nil,
          error: "no model configured for #{@runner&.runner_key} at #{@tier}"
        )
      end

      Result.new(
        model_id: default_model_id,
        provider_id: @provider&.id || @runner&.id,
        source: "default",
        error: nil
      )
    end

    private

    def success_from(entry:, source:)
      Result.new(
        model_id: entry.fetch("model_id"),
        provider_id: entry.fetch("provider_id"),
        source: source,
        error: nil
      )
    end
  end
end
