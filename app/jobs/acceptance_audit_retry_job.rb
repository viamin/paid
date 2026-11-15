# frozen_string_literal: true

# Delayed claim for a transiently failed report-only acceptance audit, so a
# bounded retry no longer depends on the periodic sweep observing the
# failure. The claim ({PartialCloseouts::RetryAcceptanceAudit}) rechecks
# eligibility, backoff, current evidence, and every ordinary admission guard
# before minting the next attempt, so a duplicated or re-delivered job
# cannot double-claim ({AgentRuns::AcceptanceAuditRetryPolicy}).
# @spec PARTIAL-CLOSEOUT-056
class AcceptanceAuditRetryJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  RETRY_BASE_DELAY = 30.minutes
  RETRY_MAX_DELAY = 60.minutes

  good_job_control_concurrency_with(
    enqueue_limit: 1,
    key: -> { "acceptance_audit_retry_#{arguments.first}" }
  )

  def self.retry_delay(attempt)
    [ RETRY_BASE_DELAY * (2**(attempt - 2)), RETRY_MAX_DELAY ].min
  end

  def perform(agent_run_id, attempt)
    # The claim re-runs the ordinary request path, which already schedules
    # run-queue processing for the successor; nothing else to dispatch.
    PartialCloseouts::RetryAcceptanceAudit.call(agent_run_id: agent_run_id, attempt: attempt)
  end
end
