# frozen_string_literal: true

module Issues
  # Runs PartialCompletionAssessment asynchronously off the GitHub poll
  # path and persists the verdict on the source issue. The poll activity
  # only persists the generic parking state and enqueues this job, so
  # the poll's 60-second activity budget is not consumed by a per-issue
  # LLM round trip (AUTO-PICK-QUEUE-012). Queue admission consumes only
  # the durable verdict this job records, so repeated polling, transient
  # harness errors, and an unchanged prerequisite cannot continuously
  # requeue the issue.
  # @spec AUTO-PICK-QUEUE-012
  class AssessPartialCompletionJob < ApplicationJob
    queue_as :low_priority

    # PartialCompletionAssessment::TIMEOUT (30s) plus headroom for a
    # verbose prompt, markdown fencing, or transient harness retries.
    self.perform_timeout = 90

    discard_on ActiveRecord::RecordNotFound

    def perform(issue_id, pull_request_number, parked_at = Time.current) # @spec AUTO-PICK-QUEUE-012
      issue = Issue.find(issue_id)
      return if issue.is_pull_request?

      assessment = Issues::PartialCompletionAssessment.call(issue: issue)
      # A transient harness error or malformed JSON inside the assessment
      # leaves the existing partial columns in place. Only an explicit
      # verdict may record or clear them.
      return unless assessment

      if assessment.partial
        issue.mark_partial_completion!(
          pull_request_number: pull_request_number,
          reason: assessment.reason,
          parked_at: parked_at
        )
      else
        issue.clear_partial_completion!
      end
    end
  end
end
