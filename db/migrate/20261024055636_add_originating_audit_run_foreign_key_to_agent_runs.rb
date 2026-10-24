class AddOriginatingAuditRunForeignKeyToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :agent_runs, :agent_runs, column: :originating_audit_run_id, validate: false
  end
end
