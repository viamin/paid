# frozen_string_literal: true

module Activities
  # Cleans up MCP sidecar containers after an agent run completes.
  # Best-effort: logs failures instead of raising so cleanup can continue.
  class CleanupMcpServersActivity < BaseActivity
    activity_name "CleanupMcpServers"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find_by(id: agent_run_id)

      unless agent_run
        logger.info(
          message: "agent_execution.cleanup_mcp_servers_skipped_missing_run",
          agent_run_id: agent_run_id
        )
        return { agent_run_id: agent_run_id }
      end

      track_phase(agent_run_id: agent_run_id, phase_key: "cleanup_mcp_servers", phase_group: "cleanup", agent_run: agent_run) do
        runner = ExecutionRunners.resolve_for(agent_run)
        runner.cleanup_mcp_servers(agent_run: agent_run)

        logger.info(
          message: "agent_execution.mcp_servers_cleaned",
          agent_run_id: agent_run_id
        )

        { agent_run_id: agent_run_id }
      end
    rescue => e
      logger.warn(
        message: "agent_execution.cleanup_mcp_servers_failed",
        agent_run_id: agent_run_id,
        error: e.message
      )
      { agent_run_id: agent_run_id }
    end
  end
end
