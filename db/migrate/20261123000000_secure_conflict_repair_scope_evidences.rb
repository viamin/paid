# frozen_string_literal: true

class SecureConflictRepairScopeEvidences < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_reference :conflict_repair_scope_evidences, :account, index: { algorithm: :concurrently }
    safety_assured do
      execute <<~SQL
        UPDATE conflict_repair_scope_evidences evidence
        SET account_id = projects.account_id
        FROM projects
        WHERE projects.id = evidence.project_id
      SQL
    end
    safety_assured { change_column_null :conflict_repair_scope_evidences, :account_id, false }

    remove_index :conflict_repair_scope_evidences, name: "index_conflict_repair_scope_evidence_binding", algorithm: :concurrently
    add_index :conflict_repair_scope_evidences,
      %i[agent_run_id pre_run_sha integration_base_sha result_sha provider_head_sha status],
      unique: true, name: "index_conflict_repair_scope_evidence_identity", algorithm: :concurrently

    safety_assured do
      execute "ALTER TABLE conflict_repair_scope_evidences ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE conflict_repair_scope_evidences FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON conflict_repair_scope_evidences
        FOR ALL USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
        WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id())
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON conflict_repair_scope_evidences"
      execute "ALTER TABLE conflict_repair_scope_evidences NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE conflict_repair_scope_evidences DISABLE ROW LEVEL SECURITY"
    end
    remove_index :conflict_repair_scope_evidences, name: "index_conflict_repair_scope_evidence_identity", algorithm: :concurrently
    add_index :conflict_repair_scope_evidences,
      %i[agent_run_id pre_run_sha integration_base_sha result_sha provider_head_sha],
      unique: true, name: "index_conflict_repair_scope_evidence_binding", algorithm: :concurrently
    remove_reference :conflict_repair_scope_evidences, :account, foreign_key: true
  end
end
