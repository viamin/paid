# frozen_string_literal: true

# Adds the per-run hardened tool sidecar container ID column so
# `Containers::McpProvisioner`'s `"tool"` install arm (RDR-073 Phase 3,
# `@spec TOOL-SIDECAR-005`) can persist and clean up the containers it
# provisions alongside the existing `mcp_sidecar_container_ids` column.
class AddToolSidecarContainerIdsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:agent_runs, :tool_sidecar_container_ids)

    add_column :agent_runs, :tool_sidecar_container_ids, :jsonb, null: false, default: [],
      comment: "Docker container IDs of marketplace tool sidecars provisioned for this run"
  end
end
