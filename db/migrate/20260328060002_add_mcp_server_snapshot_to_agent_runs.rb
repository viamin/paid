# frozen_string_literal: true

class AddMcpServerSnapshotToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :mcp_server_snapshot, :jsonb, default: [], null: false
  end
end
