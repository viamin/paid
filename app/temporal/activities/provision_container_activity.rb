# frozen_string_literal: true

module Activities
  # Provisions a Docker container with an empty workspace directory.
  #
  # The container is created before any git operations. Git clone happens
  # inside the container in the subsequent CloneRepoActivity.
  class ProvisionContainerActivity < BaseActivity
    activity_name "ProvisionContainer"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      agent_run.ensure_proxy_token!
      agent_run.provision_container

      logger.info(
        message: "agent_execution.container_provisioned",
        agent_run_id: agent_run_id
      )

      { agent_run_id: agent_run_id }
    end
  end
end
