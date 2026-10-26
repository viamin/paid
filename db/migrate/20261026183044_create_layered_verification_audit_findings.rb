# frozen_string_literal: true

class CreateLayeredVerificationAuditFindings < ActiveRecord::Migration[8.1]
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017
  def up
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :agent_run, foreign_key: true
      t.string :obligation_external_identity, null: false
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.text :summary, null: false, default: ""
      t.jsonb :source_passages, null: false, default: []
      t.jsonb :observed_behavior, null: false, default: {}
      t.jsonb :check_limitations, null: false, default: []
      t.jsonb :observations, null: false, default: []
      t.text :question
      t.jsonb :options, null: false, default: []
      t.text :deferred_reason
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_external_identity, :correspondence_claim_type, :cause_signature ],
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

  def down
    drop_table :layered_verification_findings
  end
end
