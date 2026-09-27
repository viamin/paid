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
      return complete(schedule) if current_verdict?(schedule)

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

    def current_verdict?(schedule)
      IntentConformanceVerdict.current_for(issue: schedule.issue, head_sha: schedule.pr_head_sha)&.current_for?(
        pr_head_sha: schedule.pr_head_sha, approved_design_revision: schedule.approved_design_revision
      )
    end

    def retryable_failure?(reason) = %w[unsuccessful_response no_diff transient_reviewer_failure].include?(reason)

    def complete(schedule, verdict = nil)
      schedule.update!(status: "completed", completed_at: Time.current)
      Rails.logger.info(message: "intent_conformance.review_completed", project_id: schedule.project_id, issue_id: schedule.issue_id,
        pr_head_sha: schedule.pr_head_sha, approved_design_revision: schedule.approved_design_revision,
        outcome: verdict&.outcome || "not_evaluated")
    end
  end
end
