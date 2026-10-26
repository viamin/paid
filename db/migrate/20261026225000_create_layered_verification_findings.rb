# frozen_string_literal: true

# Generated migration could not run in the task database because its PostgreSQL
# role bypasses RLS. This migration follows the existing layered-verification
# contracts and is applied by normal deployment credentials.
class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: true
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :source_passages, null: false, default: []
      t.text :observed_behavior, null: false
      t.text :check_limitations, null: false
      t.text :question, null: false
      t.jsonb :options, null: false, default: []
      t.jsonb :consequences, null: false, default: []
      t.jsonb :owner_actions, null: false, default: []
      t.jsonb :evidence_references, null: false, default: []
      t.jsonb :observations, null: false, default: []
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true,
      where: "status = 'open'",
      name: "idx_open_layered_verification_findings_identity"

    safety_assured do
      execute "ALTER TABLE layered_verification_findings ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE layered_verification_findings FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_findings
        AS PERMISSIVE FOR ALL
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = layered_verification_findings.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = layered_verification_findings.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      SQL
    end
  end
end
