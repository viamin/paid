# frozen_string_literal: true

# @spec AUTO-MERGE-011, POSTGRESQL-PERSISTENCE-001
class SecureConflictRepairScopeEvidences < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_reference :conflict_repair_scope_evidences, :account, index: { algorithm: :concurrently }
    backfill_account_ids
    safety_assured { change_column_null :conflict_repair_scope_evidences, :account_id, false }

    remove_index :conflict_repair_scope_evidences, name: "index_conflict_repair_scope_evidence_binding", algorithm: :concurrently
    add_index :conflict_repair_scope_evidences,
      %i[agent_run_id pre_run_sha integration_base_sha result_sha provider_head_sha status],
      unique: true, name: "index_conflict_repair_scope_evidence_identity", algorithm: :concurrently

    enable_tenant_rls
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Conflict-repair scope evidence records may differ only by status, which the prior unique index cannot represent losslessly."
  end

  def enable_tenant_rls
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

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON conflict_repair_scope_evidences"
      execute "ALTER TABLE conflict_repair_scope_evidences NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE conflict_repair_scope_evidences DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def backfill_account_ids
    with_tenant_bypass do
      safety_assured do
        execute <<~SQL
          UPDATE conflict_repair_scope_evidences evidence
          SET account_id = projects.account_id
          FROM projects
          WHERE projects.id = evidence.project_id
        SQL
      end
    end
  end

  def with_tenant_bypass(&)
    # The backfill joins project rows protected by tenant RLS. Scope the
    # privileged setting to this data migration so it is restored even when
    # the migration is invoked directly by a migration spec.
    ActiveRecord::Base.transaction do
      safety_assured { execute("SET LOCAL paid.bypass_tenant_rls = 'true'") }
      yield
    end
  end
end
