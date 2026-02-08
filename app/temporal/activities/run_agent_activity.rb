# frozen_string_literal: true

module Activities
  class RunAgentActivity < BaseActivity
    activity_name "RunAgent"

    def execute(agent_run_id:)
      agent_run = AgentRun.find(agent_run_id)

      prompt = agent_run.prompt_for_issue
      raise "No prompt could be built for agent run #{agent_run_id}" if prompt.blank?

      result = agent_run.execute_agent(prompt, timeout: 600)

      has_changes = check_for_changes(agent_run)

      logger.info(
        message: "agent_execution.agent_completed",
        agent_run_id: agent_run_id,
        success: result.success?,
        has_changes: has_changes
      )

      {
        agent_run_id: agent_run_id,
        success: result.success?,
        has_changes: has_changes
      }
    end

    private

    def check_for_changes(agent_run)
      return false if agent_run.worktree_path.blank?

      result = agent_run.execute_in_container("git status --porcelain", stream: false)
      return true if result[:stdout].present?

      log_result = agent_run.execute_in_container(
        "git log origin/HEAD..HEAD --oneline 2>/dev/null || true",
        stream: false
      )
      log_result[:stdout].present?
    rescue StandardError => e
      logger.warn(
        message: "agent_execution.check_changes_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      false
    end
  end
end
