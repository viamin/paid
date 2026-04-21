# frozen_string_literal: true

module Activities
  class MarkAgentRunCompleteActivity < BaseActivity
    activity_name "MarkAgentRunComplete"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      reason = input.fetch(:reason, "no_changes")
      agent_run = AgentRun.find(agent_run_id)
      return result(agent_run) if agent_run.finished?

      track_phase(agent_run_id: agent_run_id, phase_key: "mark_agent_run_complete", phase_group: "post", agent_run: agent_run, metadata: { reason: reason }) do
        completed = if agent_run.goal == "create_pr"
          agent_run.complete_no_output!(reason: reason)
        else
          agent_run.complete!
        end
        if completed
          record_draft_review_round_if_needed(agent_run)
          agent_run.log!("system", "Completed without output: #{reason}")

          if agent_run.issue && agent_run.status != "no_output"
            agent_run.issue.update!(paid_state: "completed")
          end

          logger.info(
            message: "agent_execution.completed_without_pr",
            agent_run_id: agent_run_id,
            reason: reason
          )

          ProcessRunQueueJob.perform_later
        end

        result(completed ? agent_run : agent_run.reload)
      end
    end

    private

    def result(agent_run)
      {
        agent_run_id: agent_run.id,
        skipped: agent_run.status == "cancelled",
        cancelled: agent_run.status == "cancelled"
      }
    end
  end
end
