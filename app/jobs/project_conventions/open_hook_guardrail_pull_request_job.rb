# frozen_string_literal: true

module ProjectConventions
  class OpenHookGuardrailPullRequestJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :default
    discard_on ActiveRecord::RecordNotFound

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: -> { self.class.concurrency_key_for(arguments.second) }
    )

    def self.concurrency_key_for(recommendation_id)
      "project_convention_open_hook_guardrail_pr_#{recommendation_id}"
    end

    def perform(project_id, recommendation_id, applied_by_id)
      project = Project.find(project_id)
      recommendation = project.project_convention_recommendations.find(recommendation_id)
      applied_by = User.find_by(id: applied_by_id)

      return unless recommendation.pending?

      result = ProjectConventions::OpenHookGuardrailPullRequest.call(
        project: project,
        recommendation: recommendation
      )

      recommendation.reload
      return unless recommendation.pending?

      recommendation.record_pull_request_url!(result.pull_request_url) if result.pull_request_url.present?
      recommendation.apply!(applied_by: applied_by)
      log_completion(project_id:, recommendation_id:, result:)
    rescue ProjectConventions::OpenHookGuardrailPullRequest::Error => e
      Rails.logger.warn(
        message: "project_conventions.open_hook_guardrail_pull_request_job_failed",
        project_id: project_id,
        recommendation_id: recommendation_id,
        error: e.message
      )
    end

    private

    def log_completion(project_id:, recommendation_id:, result:)
      Rails.logger.info(
        message: "project_conventions.open_hook_guardrail_pull_request_job_completed",
        project_id: project_id,
        recommendation_id: recommendation_id,
        already_configured: result.already_configured,
        pull_request_url: result.pull_request_url
      )
    end
  end
end
