# frozen_string_literal: true

module Activities
  class MarkAgentRunCompleteActivity < BaseActivity
    activity_name "MarkAgentRunComplete"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      reason = input.fetch(:reason, "no_changes")
      agent_run = AgentRun.find(agent_run_id)
      track_phase(agent_run_id: agent_run_id, phase_key: "mark_agent_run_complete", phase_group: "post", agent_run: agent_run, metadata: { reason: reason }) do
        record_draft_review_round_if_needed(agent_run)
        agent_run.complete!
        agent_run.log!("system", "Completed without PR: #{reason}")

        if agent_run.issue
          agent_run.issue.update!(paid_state: "completed")
        end

        logger.info(
          message: "agent_execution.completed_without_pr",
          agent_run_id: agent_run_id,
          reason: reason
        )

        ProcessRunQueueJob.perform_later

        { agent_run_id: agent_run_id }
      end
    end
  end
end
