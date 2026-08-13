# frozen_string_literal: true

module Activities
  # Converts a failed agent run back to rate_limited status when the failure
  # was a pre-runner infrastructure issue (Docker pull error, DNS failure,
  # etc.). The existing ProcessRunQueueJob picks up rate_limited runs once
  # rate_limited_until elapses, so no new re-queue mechanism is needed.
  #
  # Called from the workflow ensure block after cleanup, so the re-queued
  # run provisions fresh infrastructure on retry.
  class RequeueInfraFailureActivity < BaseActivity
    activity_name "RequeueInfraFailure"

    MAX_INFRA_REQUEUES = 3
    REQUEUE_DELAY = 2.minutes

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      agent_run.with_lock do
        agent_run.reload

        unless agent_run.status == "failed"
          return { agent_run_id: agent_run_id, requeued: false, reason: "not_failed" }
        end

        if agent_run.stale_requeue_count >= MAX_INFRA_REQUEUES
          agent_run.log!("system",
            "Pre-runner infra failure: requeue limit reached (#{MAX_INFRA_REQUEUES}), staying failed")
          return { agent_run_id: agent_run_id, requeued: false, reason: "limit_reached" }
        end

        previous_error = agent_run.error_message
        agent_run.rate_limit!(
          error: "Pre-runner infra failure (will retry): #{previous_error}",
          reset_at: REQUEUE_DELAY.from_now
        )
        agent_run.update_columns(stale_requeue_count: agent_run.stale_requeue_count + 1)

        # Restore issue to in_progress since the run is being retried, not
        # permanently failed. MarkAgentRunFailedActivity set it to "failed".
        if agent_run.issue&.paid_state == "failed"
          agent_run.issue.update!(paid_state: "in_progress")
        end

        agent_run.log!("system",
          "Pre-runner infra failure requeued " \
          "(attempt #{agent_run.stale_requeue_count}/#{MAX_INFRA_REQUEUES}): #{previous_error}")
      end

      logger.info(
        message: "agent_execution.infra_failure_requeued",
        agent_run_id: agent_run_id,
        requeue_count: agent_run.stale_requeue_count
      )

      { agent_run_id: agent_run_id, requeued: true }
    end
  end
end
