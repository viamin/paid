# frozen_string_literal: true

# Starts only deferred post-processing; it never re-enters coding.
# @spec PARTIAL-CLOSEOUT-045
class SourceClosureRecoveryJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default
  good_job_control_concurrency_with perform_limit: 1,
    key: -> { "source_closure_recovery_#{arguments.first}" }

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run && PartialCloseouts::SourceClosureRecovery.claim!(agent_run: agent_run)

    recovery_attempt = agent_run.reload.reconciliation.dig("source_closure_recovery", "recovery_attempt")
    Paid.temporal_client.start_workflow(Workflows::SourceClosureRecoveryWorkflow,
      { agent_run_id: agent_run.id, project_id: agent_run.project_id,
        recovery_attempt: recovery_attempt, goal: agent_run.goal },
      id: "source-closure-recovery-#{agent_run.id}-#{recovery_attempt}", task_queue: Paid.agent_task_queue)
  rescue Temporalio::Error::WorkflowAlreadyStartedError
    # A replayed job observes the already-running recovery workflow.
  rescue StandardError
    recovery_attempt ||= agent_run&.reconciliation&.dig("source_closure_recovery", "recovery_attempt")
    PartialCloseouts::SourceClosureRecovery.release_claim!(agent_run: agent_run, attempts: recovery_attempt) if recovery_attempt
    raise
  end
end
