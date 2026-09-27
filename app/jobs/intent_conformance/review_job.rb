# frozen_string_literal: true

module IntentConformance
  class ReviewJob < ApplicationJob # @spec INTENT-CONFORMANCE-011
    include GoodJob::ActiveJobExtensions::Concurrency

    class TransientReviewError < StandardError; end

    queue_as :low_priority
    self.perform_timeout = 2.minutes
    good_job_control_concurrency_with(total_limit: 2, enqueue_limit: 8,
      key: -> { self.class.concurrency_key_for(arguments.first) })
    retry_on TransientReviewError, wait: :polynomially_longer, attempts: 3 do |job, error|
      job.on_retries_exhausted(error)
    end
    discard_on ActiveRecord::RecordNotFound

    def self.concurrency_key_for(project_id) = "intent_conformance_review_project_#{project_id}"

    def perform(project_id, schedule_id)
      schedule = IntentConformanceReviewSchedule.find(schedule_id)
      return if schedule.project_id != project_id || schedule.completed?

      verdict = terminal_verdict(schedule)
      return complete(schedule, verdict) if verdict

      schedule.update!(status: "running", attempts_count: schedule.attempts_count + 1)
      review = ReviewRun.new(project: schedule.project, issue: schedule.issue, pr_head_sha: schedule.pr_head_sha)
      verdict = review.call
      schedule.update!(last_failure_reason: review.failure_reason) if review.failure_reason
      if retryable_failure?(review.failure_reason)
        schedule.update!(status: "pending")
        raise TransientReviewError, review.failure_reason
      end

      complete(schedule, verdict)
    end

    def on_retries_exhausted(error)
      schedule = IntentConformanceReviewSchedule.find_by(id: arguments.second)
      return unless schedule

      schedule.update!(last_failure_reason: error.message)
      complete(schedule)
    end

    private

    # Only an evaluated (terminal) verdict short-circuits the chain. Retryable
    # failures persist a not_evaluated verdict before raising for a bounded
    # retry, so treating a current not_evaluated verdict as terminal would
    # complete the schedule on the first retry without re-running the review —
    # the configured retries would never execute.
    def terminal_verdict(schedule)
      verdict = IntentConformanceVerdict.current_for(issue: schedule.issue, head_sha: schedule.pr_head_sha)
      return unless verdict&.current_for?(
        pr_head_sha: schedule.pr_head_sha, approved_design_revision: schedule.approved_design_revision
      )
      return if verdict.not_evaluated?

      verdict
    end

    def retryable_failure?(reason) = %w[unsuccessful_response no_diff].include?(reason)

    def complete(schedule, verdict = nil)
      schedule.update!(
        status: "completed",
        completed_at: Time.current,
        # `last_failure_reason` documents a schedule that ended without an
        # evaluated verdict (see column comment in the migration). A retry
        # that produces a real `within_scope`/`material_drift`/`uncertain`
        # outcome must clear any reason an earlier failed attempt persisted,
        # otherwise the schedule reads as `completed` with a real verdict AND
        # a stale failure reason and any reader (ops view, alert, follow-up)
        # misreads success as fail. A `not_evaluated` verdict or no verdict at
        # all means the schedule still ended without a terminal reviewer
        # outcome, so the persisted reason must survive.
        last_failure_reason: evaluated_verdict?(verdict) ? nil : schedule.last_failure_reason
      )
      Rails.logger.info(message: "intent_conformance.review_completed", project_id: schedule.project_id, issue_id: schedule.issue_id,
        pr_head_sha: schedule.pr_head_sha, approved_design_revision: schedule.approved_design_revision,
        outcome: verdict&.outcome || "not_evaluated")
    end

    def evaluated_verdict?(verdict)
      verdict.present? && !verdict.not_evaluated?
    end
  end
end
