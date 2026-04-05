# frozen_string_literal: true

module Activities
  class ResolvePrReviewPlanActivity < BaseActivity
    activity_name "ResolvePrReviewPlan"

    def execute(input)
      project = Project.find(input[:project_id])
      dispatchable_review_methods = project.dispatchable_review_methods
      paid_agent_provider =
        if dispatchable_review_methods.include?("paid_agent")
          project.paid_agent_review_provider
        end

      {
        review_enabled: project.review_enabled?,
        wait_for_reviews: project.wait_for_reviews?,
        dispatchable_review_methods: dispatchable_review_methods,
        blocking_review_methods: project.blocking_review_methods,
        ci_review_action_names: project.ci_review_action_names,
        paid_agent_review_provider_id: paid_agent_provider&.id,
        paid_agent_review_agent_type: paid_agent_provider && Provider.agent_type_for(paid_agent_provider.provider_key)
      }
    end
  end
end
