# frozen_string_literal: true

# Starts only deferred post-processing; it never re-enters coding.
# @spec PARTIAL-CLOSEOUT-045 PARTIAL-CLOSEOUT-061 PARTIAL-CLOSEOUT-060
class SourceClosureRecoveryJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default
  good_job_control_concurrency_with perform_limit: 1,
    key: -> { "source_closure_recovery_#{arguments.first}" }

  def perform(agent_run_id, operator_authorized: false)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run&.waiting_recovery?
    previous_attempt = agent_run.reconciliation.dig("source_closure_recovery", "recovery_attempt").to_i
    return if prior_execution_active?(agent_run, attempt: previous_attempt)

    claim_acquired = PartialCloseouts::SourceClosureRecovery.claim!(agent_run: agent_run,
      expected_recovery_attempt: previous_attempt, operator_authorized:)
    return unless claim_acquired

    recovery_attempt = agent_run.reload.reconciliation.dig("source_closure_recovery", "recovery_attempt")
    commit_sha = agent_run.reconciliation.dig("source_closure_recovery", "commit_sha")
    workflow_start_attempted = true
    Paid.temporal_client.start_workflow(Workflows::SourceClosureRecoveryWorkflow,
      { agent_run_id: agent_run.id, project_id: agent_run.project_id,
        recovery_attempt: recovery_attempt, goal: agent_run.goal, commit_sha: commit_sha, operator_authorized: },
      id: "source-closure-recovery-#{agent_run.id}-#{recovery_attempt}", task_queue: Paid.agent_task_queue)
  rescue Temporalio::Error::WorkflowAlreadyStartedError
    # A replayed job observes the already-running recovery workflow.
  rescue StandardError
    if claim_acquired
      recovery_attempt ||= agent_run.reconciliation.dig("source_closure_recovery", "recovery_attempt")
      PartialCloseouts::SourceClosureRecovery.release_claim!(agent_run: agent_run, attempts: recovery_attempt) if recovery_attempt
    end
    enqueue_retry(agent_run_id) if workflow_start_attempted && !operator_authorized
    raise
  end

  private

  def prior_execution_active?(agent_run, attempt:)
    return false unless attempt.positive?

    handle = Paid.temporal_client.workflow_handle("source-closure-recovery-#{agent_run.id}-#{attempt}")
    status = handle.describe(rpc_options: Temporalio::Client::RPCOptions.new(timeout: 5, override_retry: false)).status
    return false if terminal_workflow_status?(status)

    enqueue_retry(agent_run.id) unless status == Temporalio::Client::WorkflowExecutionStatus::RUNNING
    true
  rescue Temporalio::Error::RPCError => error
    return false if error.code == Temporalio::Error::RPCError::Code::NOT_FOUND

    enqueue_retry(agent_run.id)
    Rails.logger.warn(message: "source_closure_recovery.status_unavailable", agent_run_id: agent_run.id, code: error.code)
    true
  end

  def terminal_workflow_status?(status)
    statuses = Temporalio::Client::WorkflowExecutionStatus
    [ statuses::COMPLETED, statuses::FAILED, statuses::CANCELED, statuses::TERMINATED, statuses::TIMED_OUT ].include?(status)
  end

  def enqueue_retry(agent_run_id)
    self.class.set(wait: PartialCloseouts::SourceClosureRecovery::RETRY_DELAY).perform_later(agent_run_id)
  end
end
