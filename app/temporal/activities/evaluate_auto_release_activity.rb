# frozen_string_literal: true

module Activities
  class EvaluateAutoReleaseActivity < BaseActivity
    # @spec AUTOMATION-ACTIVATION-003 @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-016
    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { evaluated: false, project_missing: true } unless project
      unless auto_release_enabled?(project)
        return { evaluated: false, reason: "disabled" }
      end

      AutoReleaseEvaluationJob.perform_later(project_id)

      { evaluated: true }
    end

    private

    def auto_release_enabled?(project)
      Automation::FeatureActivation.phase_authorized?(project:, capability: "auto_release") &&
        (project.auto_release_enabled? || Automation::FeatureActivation.any_pull_request_feature_enabled?(project:, feature: "auto_release"))
    end
  end
end
