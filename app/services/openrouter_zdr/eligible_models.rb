# frozen_string_literal: true

module OpenrouterZdr
  class EligibleModels
    Result = Data.define(:models, :catalog_state)

    def self.call(runner:, projects: [])
      new(runner:, projects:).call
    end

    # @spec FREE-MODEL-SYNC-013
    def initialize(runner:, projects: [])
      @runner = runner
      @projects = projects
    end

    # @spec FREE-MODEL-SYNC-013
    def call
      Result.new(models: candidates.select { |model| permitted?(model) }, catalog_state: OpenrouterZdrCatalogState.instance)
    end

    private

    attr_reader :runner, :projects

    def candidates
      ids = OpenrouterZdrModel.active.pluck(:model_id).index_with(true)
      Runners::ModelOptions.call(runner_key: runner.runner_key, api_provider: "openrouter", auth_type: runner.auth_type)
        .select(&:model?).map(&:model).select { |model| ids.key?(model.model_id) && model.supports_tools? }
    end

    def permitted?(model)
      return false unless verified_models.permitted?(model.model_id, model: model)
      return false if unavailable?(model)

      projects.all? { |project| project_permits?(project, model) }
    end

    def project_permits?(project, model)
      verified_models.permitted?(model.model_id, model: model, project: project) &&
        PolicyControls::Evaluate.call(project: project, runner: runner, model: model).violations.empty?
    end

    def verified_models
      @verified_models ||= Runners::VerifiedModels.new(runner)
    end

    def unavailable?(model)
      ModelAvailabilityCheck.where(llm_model: model, runner_key: runner.runner_key, auth_type: runner.auth_type,
        account: [ runner.user.account, nil ]).any? { |check| check.status == "unavailable" && !check.stale? }
    end
  end
end
