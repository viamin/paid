# frozen_string_literal: true

module AgentRuns
  # Resolves persisted resource ownership for cleanup decisions. A run can be
  # resumed after a worker loss, so workflow-local provisioning progress is not
  # sufficient evidence that it owns (or does not own) a resource.
  class CleanupOwnership
    def self.for(agent_run)
      new(agent_run).to_h
    end

    def initialize(agent_run)
      @agent_run = agent_run
    end

    def to_h
      {
        container: container_owned?,
        mcp_servers: mcp_servers_owned?,
        services: service_containers_owned?,
        worktree: worktree_owned?,
        janitor: container_owned?
      }
    end

    private

    attr_reader :agent_run

    def container_owned?
      agent_run.container_id.present? ||
        agent_run.runner_handle.present? ||
        ExecutionResource.active_or_pending.where(agent_run:).exists?
    end

    def mcp_servers_owned?
      Array(agent_run.mcp_sidecar_container_ids).present? ||
        Array(agent_run.tool_sidecar_container_ids).present?
    end

    def service_containers_owned?
      Array(agent_run.service_container_ids).present?
    end

    def worktree_owned?
      agent_run.worktree&.active? == true
    end
  end
end
