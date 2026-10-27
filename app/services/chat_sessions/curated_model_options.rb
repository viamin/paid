# frozen_string_literal: true

module ChatSessions
  # @spec CHAT-SESSION-PREFERENCES-003
  # @spec CHAT-API-026 MODEL-AVAILABILITY-008
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
    Resolution = Data.define(:option, :rejection_reasons)

    def self.for_runner(runner, projects: [])
      new(runner, projects: projects).options
    end

    def self.resolve(runner:, tier: "low", projects: [])
      resolve_with_reasons(runner:, tier:, projects:).option
    end

    def self.resolve_with_reasons(runner:, tier: "low", projects: [])
      new(runner, projects: projects).resolve(tier:)
    end

    def initialize(runner, projects: [])
      @runner = runner
      @projects = projects
    end

    def options
      Models::CatalogSnapshot.read { options_from_snapshot }
    end

    def resolve(tier: "low")
      Models::CatalogSnapshot.read { resolution_from_snapshot(tier.to_s) }
    end

    private

    attr_reader :runner, :projects

    Option = Data.define(:tier, :model_id, :label)

    def options_from_snapshot
      compatible_models.group_by(&:tier).filter_map do |tier, models|
        next unless TIERS.key?(tier)

        model = preferred_model(tier, models)
        Option.new(tier:, model_id: model.model_id, label: "#{TIERS.fetch(tier)}: #{model.model_id}") if model
      end.sort_by { |option| TIERS.keys.index(option.tier) }
    end

    def resolution_from_snapshot(tier)
      Resolution.new(options_from_snapshot.find { |option| option.tier == tier }, rejection_reasons_for(tier))
    end

    def compatible_models
      candidate_models.reject { |model| unavailable?(model) }.select { |model| permitted?(model) }
    end

    def rejection_reasons_for(tier)
      tier_candidates = candidate_models.select { |model| model.tier == tier }
      return [ :catalog_empty ] if tier_candidates.empty?

      tool_capable = tier_candidates.select(&:supports_tools?)
      return [ :capability_mismatch ] if tool_capable.empty?

      available = tool_capable.reject { |model| unavailable?(model) }
      return [ :unavailable ] if available.empty?

      verified = available.select { |model| verified_permitted?(model) }
      return [ :verified_model_restriction ] if verified.empty?

      return [ :operator_policy ] if verified.none? { |model| policy_permitted?(model) }

      []
    end

    def candidate_models
      @candidate_models ||= Runners::ModelOptions.call(
        runner_key: runner.runner_key,
        api_provider: model_provider,
        auth_type: runner.auth_type
      ).select(&:model?).map(&:model).select(&:supports_tools?)
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
      availability_checks_by_model_id.fetch(model.id, []).any? { |check| check.status == "unavailable" && !check.stale? }
    end

    def permitted?(model)
      verified_permitted?(model) && policy_permitted?(model)
    end

    def verified_permitted?(model)
      return false unless verified_models.permitted?(model.model_id, model: model)

      projects.all? { |project| verified_models.permitted?(model.model_id, model: model, project: project) }
    end

    def policy_permitted?(model)
      projects.all? do |project|
        PolicyControls::Evaluate.call(project: project, runner: runner, model: model).violations.empty?
      end
    end

    def verified_models
      @verified_models ||= Runners::VerifiedModels.new(runner)
    end

    def availability_checks_by_model_id
      @availability_checks_by_model_id ||= ModelAvailabilityCheck.where(
        llm_model_id: compatible_model_ids,
        runner_key: runner.runner_key,
        auth_type: runner.auth_type,
        account: [ runner.user.account, nil ]
      ).group_by(&:llm_model_id)
    end

    def compatible_model_ids
      candidate_models.map(&:id)
    end
  end
end
