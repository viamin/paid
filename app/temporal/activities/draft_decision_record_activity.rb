# frozen_string_literal: true

module Activities
  # Drafts a decision record from a completed agent run.
  #
  # Best-effort: failures are logged but do not raise, so they
  # don't break the agent execution workflow.
  class DraftDecisionRecordActivity < BaseActivity
    activity_name "DraftDecisionRecord"

    def execute(input)
      agent_run_id = input[:agent_run_id]

      # Ensure idempotency: if a DecisionRecord already exists for this agent_run,
      # reuse it instead of drafting a new one (Temporal activities may be retried).
      if (existing_record = DecisionRecord.find_by(agent_run_id: agent_run_id))
        logger.info(
          message: "knowledge.decisions.draft_exists",
          agent_run_id: agent_run_id,
          decision_record_id: existing_record.id
        )

        return { agent_run_id: agent_run_id, decision_record_id: existing_record.id, success: true }
      end

      agent_run = AgentRun.find(agent_run_id)

      track_phase(agent_run_id: agent_run_id, phase_key: "draft_decision_record", phase_group: "post", agent_run: agent_run) do
        record = Knowledge::Decisions::Draft.call(agent_run: agent_run)

        if record
          logger.info(
            message: "knowledge.decisions.draft_created",
            agent_run_id: agent_run_id,
            decision_record_id: record.id
          )

          { agent_run_id: agent_run_id, decision_record_id: record.id, success: true }
        else
          logger.info(
            message: "knowledge.decisions.draft_skipped",
            agent_run_id: agent_run_id
          )

          { agent_run_id: agent_run_id, decision_record_id: nil, success: true }
        end
      end
    rescue => e
      logger.warn(
        message: "knowledge.decisions.draft_failed",
        agent_run_id: agent_run_id,
        error_class: e.class.name,
        error: e.message
      )

      { agent_run_id: agent_run_id, decision_record_id: nil, success: false, error: e.message }
    end
  end
end
