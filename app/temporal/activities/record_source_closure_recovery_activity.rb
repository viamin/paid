# frozen_string_literal: true

module Activities
  # Parks a run whose closeout assessment could not complete.
  #
  # The agent's coding work and its pushed revision are already good, so the
  # run is not failed: it is held in a durable waiting state that names the
  # failed step, the pushed branch and commit, the attempts, and the next
  # retry or operator action.
  # @spec PARTIAL-CLOSEOUT-043
  class RecordSourceClosureRecoveryActivity < BaseActivity
    activity_name "RecordSourceClosureRecovery"

    def execute(input) # @spec PARTIAL-CLOSEOUT-043
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      state = PartialCloseouts::SourceClosureRecoveryState.park(agent_run)
      agent_run.pause_for_source_closure_recovery!

      logger.warn(
        message: "partial_closeout.assessment_recovery_waiting",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        failure_category: state["failure_category"],
        attempts: state["attempts"],
        next_retry_at: state["next_retry_at"]
      )

      { agent_run_id: agent_run.id, status: state["status"], next_retry_at: state["next_retry_at"] }
    end
  end
end
