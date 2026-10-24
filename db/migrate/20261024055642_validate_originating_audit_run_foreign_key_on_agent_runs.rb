class ValidateOriginatingAuditRunForeignKeyOnAgentRuns < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :agent_runs, :agent_runs, column: :originating_audit_run_id
  end
end
