# frozen_string_literal: true

class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :nullify }
      t.references :originating_audit_run, null: false, foreign_key: { to_table: :agent_runs, on_delete: :restrict }
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :detail, null: false, default: {}
      t.timestamps
    end

    add_index :layered_verification_findings,
      "project_id, obligation_id, COALESCE(correspondence_claim_id, 0), cause_signature",
      unique: true,
      name: "index_layered_verification_findings_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, null: false, foreign_key: { to_table: :layered_verification_check_results, on_delete: :restrict }
      t.references :agent_run, null: false, foreign_key: true
      t.jsonb :detail, null: false, default: {}
      t.timestamps
    end

    reversible do |dir|
      dir.up { enable_rls }
    end
  end

  private

  def enable_rls
    safety_assured do
      execute <<~SQL
        ALTER TABLE layered_verification_findings ENABLE ROW LEVEL SECURITY;
        ALTER TABLE layered_verification_findings FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON layered_verification_findings
          USING (paid_tenant_bypass() OR project_id IN (
            SELECT id FROM projects WHERE account_id = paid_current_account_id()
          ))
          WITH CHECK (paid_tenant_bypass() OR project_id IN (
            SELECT id FROM projects WHERE account_id = paid_current_account_id()
          ));
      SQL
      execute <<~SQL
        ALTER TABLE layered_verification_finding_observations ENABLE ROW LEVEL SECURITY;
        ALTER TABLE layered_verification_finding_observations FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON layered_verification_finding_observations
          USING (paid_tenant_bypass() OR finding_id IN (
            SELECT f.id FROM layered_verification_findings f
            INNER JOIN projects p ON p.id = f.project_id
            WHERE p.account_id = paid_current_account_id()
          ))
          WITH CHECK (paid_tenant_bypass() OR finding_id IN (
            SELECT f.id FROM layered_verification_findings f
            INNER JOIN projects p ON p.id = f.project_id
            WHERE p.account_id = paid_current_account_id()
          ));
      SQL
    end
  end
end
