# frozen_string_literal: true

module Activities
  class RunAgentActivity < BaseActivity
    activity_name "RunAgent"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      prompt = agent_run.effective_prompt
      raise Temporalio::Error::ApplicationError.new("No prompt available for agent run", type: "MissingPrompt") unless prompt

      result = agent_run.execute_agent(prompt)

      unless result.success?
        raise Temporalio::Error::ApplicationError.new(
          "Agent execution failed: #{result.error}",
          type: "AgentExecutionFailed"
        )
      end

      has_changes = check_for_changes(agent_run)

      {
        agent_run_id: agent_run_id,
        success: true,
        has_changes: has_changes
      }
    end

    private

    def check_for_changes(agent_run)
      return false unless agent_run.container_id.present?

      container_service = Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: agent_run.container_id
      )

      git_ops = Containers::GitOperations.new(
        container_service: container_service,
        agent_run: agent_run
      )

      git_ops.has_changes?
    rescue => e
      logger.warn(
        message: "agent_execution.check_changes_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      false
    end
  end
end
