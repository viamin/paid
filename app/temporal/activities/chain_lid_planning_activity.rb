# frozen_string_literal: true

module Activities
  # @spec CREATE-FEATURE-004
  #
  # Chains a completed create_feature run into a lid_planning run when the
  # project is LID-enabled. The new lid_planning run receives the RDR as a
  # named plan-doc reference, converting the RDR's authored sections into LID
  # artifacts (HLD/LLD/EARS per RDR-051's conversion table).
  #
  # This activity is intentionally kept narrow: it checks the LID gate and
  # creates the follow-up, leaving the prompt composition and execution to the
  # existing lid_planning machinery (BuildForLidPlanning, AgentExecutionWorkflow).
  class ChainLidPlanningActivity < BaseActivity
    activity_name "ChainLidPlanning"

    def execute(input)
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      plan_doc_source = input[:plan_doc_source]

      unless agent_run.project.lid_mode.present?
        logger.info(
          message: "chain_lid_planning.skipped_lid_not_enabled",
          agent_run_id: agent_run.id,
          project_id: agent_run.project_id
        )
        return { skipped: true, reason: "lid_mode_not_set" }
      end

      logger.info(
        message: "chain_lid_planning.creating_followup",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        plan_doc_source: plan_doc_source
      )

      followup = AgentRun.create!(
        project: agent_run.project,
        goal: "lid_planning",
        plan_doc_source: plan_doc_source,
        external_metadata: (plan_doc_source.present? ? { "plan_docs" => [ { "name" => plan_doc_source } ] } : {}),
        initiating_user_id: agent_run.initiating_user_id,
        agent_type: agent_run.agent_type,
        runner_id: agent_run.runner_id,
        trigger_type: "automatic",
        auto_pick: true,
        status: "queued"
      )

      ProcessRunQueueJob.perform_later

      { agent_run_id: followup.id, queued: true }
    rescue ActiveRecord::RecordNotUnique => e
      message = e.cause&.message || e.message
      raise unless message&.include?("idx_agent_runs_unique_active_lid_planning")

      logger.info(
        message: "chain_lid_planning.skipped_active_exists",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id
      )
      { skipped: true, reason: "active_lid_planning_exists" }
    end
  end
end
