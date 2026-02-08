# frozen_string_literal: true

module Activities
  class CleanupContainerActivity < BaseActivity
    activity_name "CleanupContainer"

    def execute(agent_run_id:)
      agent_run = AgentRun.find(agent_run_id)
      agent_run.cleanup_container

      logger.info(
        message: "agent_execution.container_cleaned",
        agent_run_id: agent_run_id
      )

      { agent_run_id: agent_run_id }
    end
  end
end
