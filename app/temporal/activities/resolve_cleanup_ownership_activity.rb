# frozen_string_literal: true

module Activities
  # Reads durable resource references before workflow cleanup. This is kept at
  # an activity boundary because a workflow may not query Active Record during
  # replay, and because resumed runs can own resources acquired before this
  # worker instance started.
  class ResolveCleanupOwnershipActivity < BaseActivity
    activity_name "ResolveCleanupOwnership"

    def execute(input) # @spec TEMPORAL-ORCHESTRATION-016
      agent_run = AgentRun.find_by(id: input.fetch(:agent_run_id))
      return no_owned_resources unless agent_run

      AgentRuns::CleanupOwnership.for(agent_run)
    end

    private

    def no_owned_resources
      { container: false, mcp_servers: false, services: false, worktree: false, janitor: false }
    end
  end
end
