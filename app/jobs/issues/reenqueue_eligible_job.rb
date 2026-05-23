# frozen_string_literal: true

module Issues
  class ReenqueueEligibleJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :default

    NO_RUNNER_RETRY_BASE_DELAY = 30.seconds
    NO_RUNNER_RETRY_MAX_DELAY = 1.minute
    MAX_NO_RUNNER_RETRIES = 3

    good_job_control_concurrency_with(
      enqueue_limit: 1,
      key: -> { "reenqueue_eligible_issue_#{arguments.first}" }
    )

    def self.schedule_no_runner_retry(issue_id, no_runner_retry_count:)
      return if no_runner_retry_count >= MAX_NO_RUNNER_RETRIES

      next_retry_count = no_runner_retry_count + 1
      wait = no_runner_retry_delay(next_retry_count)

      set(wait: wait).perform_later(issue_id, no_runner_retry_count: next_retry_count)

      { retry_count: next_retry_count, wait: wait }
    end

    def self.no_runner_retry_delay(retry_count)
      [ NO_RUNNER_RETRY_BASE_DELAY * (2**(retry_count - 1)), NO_RUNNER_RETRY_MAX_DELAY ].min
    end

    def perform(issue_id, no_runner_retry_count: 0)
      issue = Issue.includes(:project).find_by(id: issue_id)
      return unless issue
      return if issue.is_pull_request?
      return unless issue.paid_state.in?(%w[new planning failed completed])
      return unless AutoPickProjectGate.call(issue.project)

      EnqueueEligible.call(
        issue,
        project: issue.project,
        skip_project_gate: true,
        no_runner_retry_count: no_runner_retry_count
      )
    rescue => e
      Rails.logger.error(
        message: "enqueue_eligible.issue_state_change_failed",
        issue_id: issue_id,
        no_runner_retry_count: no_runner_retry_count,
        error: e.message
      )
    end
  end
end
