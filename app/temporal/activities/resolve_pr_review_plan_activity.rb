# frozen_string_literal: true

module Activities
  class ResolvePrReviewPlanActivity < BaseActivity
    activity_name "ResolvePrReviewPlan"

    def execute(input)
      project = Project.find(input[:project_id])

      {
        review_enabled: project.review_enabled?,
        wait_for_reviews: project.wait_for_reviews?,
        dispatchable_review_methods: project.dispatchable_review_methods,
        blocking_review_methods: project.blocking_review_methods,
        ci_review_action_names: project.ci_review_action_names,
        paid_agent_review_provider_id: project.paid_agent_review_provider_id,
        paid_agent_review_agent_type: project.paid_agent_review_agent_type
      }
    end
  end
end
