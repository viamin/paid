# frozen_string_literal: true

class AddToolSidecarSnapshotToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:agent_runs, :tool_sidecar_snapshot)

    add_column :agent_runs, :tool_sidecar_snapshot, :jsonb, default: [], null: false,
      comment: "Marketplace tool sidecar definitions snapshotted when the run attaches entries"
  end
end
