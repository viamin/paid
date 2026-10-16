# frozen_string_literal: true

module ChatSessions
  # @spec CHAT-SESSION-PREFERENCES-003
  # @spec CHAT-API-026
  class CuratedModelOptions
    TIERS = {
      "low" => "Low",
      "mid" => "Medium",
      "high" => "High"
    }.freeze
    OPENAI_MODEL_IDS = {
      "low" => "gpt-5.6-luna",
      "mid" => "gpt-5.6-terra",
      "high" => "gpt-5.6-sol"
    }.freeze

    def self.for_runner(runner)
      new(runner).options
    end

    def self.resolve(runner:, tier: "low")
      for_runner(runner).find { |option| option.tier == tier.to_s }
    end

    def initialize(runner)
      @runner = runner
    end

    def options
      compatible_models.group_by(&:tier).filter_map do |tier, models|
        next unless TIERS.key?(tier)

        model = preferred_model(tier, models)
        Option.new(tier:, model_id: model.model_id, label: "#{TIERS.fetch(tier)}: #{model.model_id}") if model
      end.sort_by { |option| TIERS.keys.index(option.tier) }
    end

    private

    attr_reader :runner

    Option = Data.define(:tier, :model_id, :label)

    def compatible_models
      Runners::ModelOptions.call(
        runner_key: runner.runner_key,
        api_provider: model_provider,
        auth_type: runner.auth_type
      ).select(&:model?).map(&:model).reject { |model| unavailable?(model) }
    end

    def preferred_model(tier, models)
      models.find { |model| model.model_id == preferred_model_ids[tier] } ||
        models.max_by { |model| [ model.capability_score.to_f, model.model_id ] }
    end

    def preferred_model_ids
      model_provider == "openai" ? OPENAI_MODEL_IDS : {}
    end

    def model_provider
      @model_provider ||= Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner.runner_key] ||
        runner.direct_outbound_llm_model_provider
    end

    def unavailable?(model)
      availability_checks(model).any? { |check| check.status == "unavailable" && !check.stale? }
    end

    def availability_checks(model)
      ModelAvailabilityCheck.where(
        llm_model: model,
        runner_key: runner.runner_key,
        auth_type: runner.auth_type,
        account: [ runner.user.account, nil ]
      )
    end
  end
end
