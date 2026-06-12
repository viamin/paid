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
            paid_state = agent_run.analyze_issue_goal? ? "analyzed" : "completed"
            agent_run.issue.update!(paid_state: paid_state)
          end

          logger.info(
            message: "agent_execution.completed_without_pr",
            agent_run_id: agent_run_id,
            reason: reason
          )

          record_dispatch_circuit_breaker_outcome(agent_run)
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

    def record_dispatch_circuit_breaker_outcome(agent_run)
      return unless agent_run.final_runner.present?
      return unless agent_run.project&.account

      ::AgentRuns::DispatchCircuitBreaker.record_outcome!(
        account: agent_run.project.account,
        runner_name: agent_run.final_runner,
        success: true
      )
    rescue => e
      logger.warn(
        message: "dispatch_circuit_breaker.record_outcome_error",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
    end
  end
end
