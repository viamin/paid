# frozen_string_literal: true

class AddMcpSidecarContainerIdsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :mcp_sidecar_container_ids, :jsonb, null: false, default: [],
      comment: "Docker container IDs of MCP sidecar containers provisioned for this run"
  end
end
