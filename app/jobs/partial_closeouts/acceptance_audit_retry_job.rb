# frozen_string_literal: true

# frozen_string: true

module PartialCloseouts
  # Delayed retry for a transiently failed report-only acceptance audit,
  # claimed through the shared retry mechanism
  # (`AgentRuns::RetryAttempt` + `AcceptanceAuditRetryPolicy`). The claim
  # rechecks current evidence, assessment staleness, and every ordinary
  # audit admission guard under lock, so overlap between this job, the
  # periodic sweep, and an operator-requested audit resolves to one run.
  # The periodic sweep re-derives the same state from durable rows, so a
  # lost job cannot strand a retryable evidence generation.
  # @spec PARTIAL-CLOSEOUT-056
  class AcceptanceAuditRetryJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :default

    good_job_control_concurrency_with(
      enqueue_limit: 1,
      key: -> { "acceptance_audit_retry_#{arguments.first}" }
    )

    def self.retry_delay(attempt)
      AcceptanceAuditRetryPolicy.retry_delay(attempt)
    end

    def perform(agent_run_id, attempt)
      result = AcceptanceAuditRetryPolicy.retry_mechanism.claim(agent_run_id: agent_run_id, attempt: attempt)
      return unless result.claimed?

      Rails.logger.info(
        message: "partial_closeout.acceptance_audit_auto_retry",
        component: "partial_closeout",
        original_agent_run_id: result.agent_run.id,
        new_agent_run_id: result.successor.id,
        issue_id: result.agent_run.issue_id,
        project_id: result.agent_run.project_id,
        attempt: attempt,
        max_attempts: AcceptanceAuditRetryPolicy.new.maximum_attempts
      )

      ProcessRunQueueJob.perform_later
    end
  end
end
