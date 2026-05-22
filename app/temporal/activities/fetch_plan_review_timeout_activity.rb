# frozen_string_literal: true

module Activities
  class FetchPlanReviewTimeoutActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { plan_review_timeout_hours: 24, project_missing: true } unless project

      { plan_review_timeout_hours: project.plan_review_timeout_hours }
    end
  end
end
