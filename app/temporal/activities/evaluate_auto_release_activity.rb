# frozen_string_literal: true

module Activities
  class EvaluateAutoReleaseActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { evaluated: false, project_missing: true } unless project
      return { evaluated: false, reason: "disabled" } unless project.auto_release_enabled?

      AutoReleaseEvaluationJob.perform_later(project_id)

      { evaluated: true }
    end
  end
end
