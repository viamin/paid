# frozen_string_literal: true

# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017
class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :originating_audit_run, null: false, foreign_key: { to_table: :agent_runs, on_delete: :restrict }
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :state, null: false, default: "open"
      t.jsonb :source_passages, null: false, default: []
      t.text :observed_behavior, null: false
      t.text :limitations, null: false
      t.text :decision_question, null: false
      t.jsonb :options, null: false, default: []
      t.jsonb :observations, null: false, default: []
      t.timestamps
    end
    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true, name: "index_layered_verification_findings_identity"
    safety_assured do
      execute "ALTER TABLE layered_verification_findings ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE layered_verification_findings FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_findings
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM projects
          WHERE projects.id = layered_verification_findings.project_id
            AND projects.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM projects
          WHERE projects.id = layered_verification_findings.project_id
            AND projects.account_id = paid_current_account_id()
        ))
      SQL
    end
  end
end
