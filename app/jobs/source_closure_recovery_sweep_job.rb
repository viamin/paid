# frozen_string_literal: true

# Retries source-closure assessments that could not complete after the agent's
# work was pushed.
#
# The sweep only picks up runs whose durable recovery state is pending and
# whose backoff window elapsed. Each recovery is claimed atomically, so a
# replayed sweep, a manual retry, and a concurrent sweep cannot publish a
# second pull request for the same run.
# @spec PARTIAL-CLOSEOUT-043
class SourceClosureRecoverySweepJob < ApplicationJob
  queue_as :maintenance

  BATCH_SIZE = 10

  def perform
    due_runs.each do |agent_run|
      RecoverSourceClosureAssessmentJob.perform_later(agent_run.id)
    end
  end

  private

  def due_runs
    AgentRun.awaiting_source_closure_recovery
      .where("(reconciliation -> ? ->> 'next_retry_at')::timestamptz <= ?",
        PartialCloseouts::SourceClosureRecoveryState::KEY, Time.current)
      .limit(BATCH_SIZE)
  end
end
