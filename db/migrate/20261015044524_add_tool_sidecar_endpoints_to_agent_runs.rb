# frozen_string_literal: true

class AddToolSidecarEndpointsToAgentRuns < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:agent_runs, :tool_sidecar_endpoints)

    add_column :agent_runs, :tool_sidecar_endpoints, :jsonb, null: false, default: [],
      comment: "Run-scoped endpoint manifest for provisioned marketplace tool sidecars"
  end

  def down
    return unless column_exists?(:agent_runs, :tool_sidecar_endpoints)

    remove_column :agent_runs, :tool_sidecar_endpoints
  end
end
