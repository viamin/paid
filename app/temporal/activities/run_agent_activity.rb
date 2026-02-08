# frozen_string_literal: true

module Activities
  class RunAgentActivity < BaseActivity
    activity_name "RunAgent"

    def execute(agent_run_id:)
      agent_run = AgentRun.find(agent_run_id)

      prompt = agent_run.prompt_for_issue
      raise Temporalio::Error::ApplicationError.new("No issue attached to agent run", type: "MissingIssue") unless prompt

      result = agent_run.execute_agent(prompt)

      has_changes = check_for_changes(agent_run)

      {
        agent_run_id: agent_run_id,
        success: result.success?,
        has_changes: has_changes
      }
    end

    private

    def check_for_changes(agent_run)
      return false unless agent_run.worktree_path.present?

      result = agent_run.execute_in_container("git diff --stat HEAD", stream: false)
      result.success? && result[:stdout].present?
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
