# frozen_string_literal: true

module Activities
  class ProvisionContainerActivity < BaseActivity
    activity_name "ProvisionContainer"

    def execute(agent_run_id:, worktree_path:)
      agent_run = AgentRun.find(agent_run_id)
      result = agent_run.provision_container

      logger.info(
        message: "agent_execution.container_provisioned",
        agent_run_id: agent_run_id,
        container_id: result[:container_id]
      )

      { agent_run_id: agent_run_id, container_id: result[:container_id] }
    end
  end
end
