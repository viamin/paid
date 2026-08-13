# frozen_string_literal: true

module Activities
  class EvaluateDependabotAutoMergeActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { evaluated: false, project_missing: true } unless project
      return { evaluated: false, reason: "disabled" } unless project.auto_merge_dependabot?

      DependabotAutoMergeJob.perform_later(project_id)

      { evaluated: true }
    end
  end
end
