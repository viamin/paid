# frozen_string_literal: true

module ChatSessions
  # @spec CHAT-SESSION-PREFERENCES-003
  # @spec CHAT-API-026
  class CuratedModelOptions
    Resolution = Data.define(:option, :rejection_reasons)
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

    def self.for_runner(runner, projects: [])
      Models::CatalogSnapshot.consistent_read { new(runner, projects: projects).options }
    end

    def self.resolve(runner:, tier: "low", projects: [])
      resolve_with_diagnostics(runner:, tier:, projects:).option
    end

    def self.resolve_with_diagnostics(runner:, tier: "low", projects: [])
      Models::CatalogSnapshot.consistent_read do
        curated = new(runner, projects: projects)
        option = curated.options.find { |candidate| candidate.tier == tier.to_s }
        Resolution.new(option:, rejection_reasons: option ? [] : curated.rejection_reasons)
      end
    end

    def initialize(runner, projects: [])
      @runner = runner
      @projects = projects
    end

    def options
      compatible_models.group_by(&:tier).filter_map do |tier, models|
        next unless TIERS.key?(tier)

        model = preferred_model(tier, models)
        Option.new(tier:, model_id: model.model_id, label: "#{TIERS.fetch(tier)}: #{model.model_id}") if model
      end.sort_by { |option| TIERS.keys.index(option.tier) }
    end

    private

    attr_reader :runner, :projects

    Option = Data.define(:tier, :model_id, :label)

    def compatible_models
      candidate_models.reject { |model| unavailable?(model) }.select { |model| permitted?(model) }
    end

    def rejection_reasons
      return [ :catalog_empty ] if catalog_models.empty?
      return [ :runner_incompatible ] if runner_compatible_models.empty?
      return [ :capability_mismatch ] if candidate_models.empty?

      available_models = candidate_models.reject { |model| unavailable?(model) }
      return [ :unavailable ] if available_models.empty?

      verified = available_models.select { |model| verified_models.permitted?(model.model_id, model: model) }
      return [ :verified_model_restriction ] if verified.empty?

      permitted = verified.select { |model| policy_permitted?(model) }
      return [ :operator_policy ] if permitted.empty?
      return [ :low_tier_unavailable ] unless permitted.any? { |model| model.tier == "low" }

      [ :operator_policy ]
    end
    public :rejection_reasons

    def candidate_models
      @candidate_models ||= runner_compatible_models.select(&:supports_tools?)
    end

    def runner_compatible_models
      @runner_compatible_models ||= Runners::ModelOptions.call(
        runner_key: runner.runner_key,
        api_provider: model_provider,
        auth_type: runner.auth_type
      ).select(&:model?).map(&:model)
    end

    def catalog_models
      @catalog_models ||= LlmModel.active.by_provider(model_provider).to_a
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
      return false unless verified_models.permitted?(model.model_id, model: model)

      policy_permitted?(model)
    end

    def policy_permitted?(model)
      projects.all? do |project|
        verified_models.permitted?(model.model_id, model: model, project: project) &&
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
