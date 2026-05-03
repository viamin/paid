# frozen_string_literal: true

class RemovePendingStatusFromAgentRuns < ActiveRecord::Migration[8.1]
  def up
    agent_run = Class.new(ActiveRecord::Base) { self.table_name = "agent_runs" }
    now = Time.current

    agent_run.where(status: "pending").where.not(temporal_workflow_id: nil)
             .update_all(status: "queued", updated_at: now)

    agent_run.where(status: "pending")
             .update_all(status: "queued", temporal_workflow_id: "claimed", updated_at: now)

    change_column_default :agent_runs, :status, from: "pending", to: "queued"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
