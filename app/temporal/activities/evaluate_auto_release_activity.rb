# frozen_string_literal: true

module Activities
  class EvaluateAutoReleaseActivity < BaseActivity
    # @spec AUTOMATION-ACTIVATION-003
    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { evaluated: false, project_missing: true } unless project
      unless project.auto_release_enabled? || Automation::FeatureActivation.any_pull_request_feature_enabled?(project:, feature: "auto_release")
        return { evaluated: false, reason: "disabled" }
      end

      AutoReleaseEvaluationJob.perform_later(project_id)

      { evaluated: true }
    end
  end
end
