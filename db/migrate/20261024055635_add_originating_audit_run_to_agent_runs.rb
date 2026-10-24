class AddOriginatingAuditRunToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :agent_runs, :originating_audit_run,
      index: { algorithm: :concurrently }
  end
end
