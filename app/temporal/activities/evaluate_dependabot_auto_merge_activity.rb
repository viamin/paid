# frozen_string_literal: true

module Activities
  class EvaluateDependabotAutoMergeActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { evaluated: false, project_missing: true } unless project
      unless dependabot_evaluation_enabled?(project)
        return { evaluated: false, reason: "disabled" }
      end

      DependabotAutoMergeJob.perform_later(project_id)

      { evaluated: true }
    end

    private

    # @spec AUTO-MERGE-008 — per-PR activation labels can authorize
    # individual Dependabot PRs even when the project-level dependabot
    # auto-merge mode is off.
    def dependabot_evaluation_enabled?(project)
      project.auto_merge_dependabot? ||
        Automation::FeatureActivation.any_pull_request_feature_enabled?(project:, feature: "auto_merge")
    end
  end
end
