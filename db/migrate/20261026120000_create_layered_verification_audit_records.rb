# frozen_string_literal: true

class CreateLayeredVerificationAuditRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: true
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.text :source_passages, null: false
      t.text :observed_behavior, null: false
      t.text :limitations, null: false
      t.jsonb :decision, null: false, default: {}
      t.jsonb :evidence, null: false, default: {}
      t.datetime :deferred_at
      t.text :deferral_reason
      t.timestamps
    end
    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true, name: "index_layered_verification_findings_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, null: false, foreign_key: { to_table: :layered_verification_check_results, on_delete: :restrict }
      t.references :agent_run, null: false, foreign_key: true
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end
    add_index :layered_verification_finding_observations, [ :finding_id, :check_result_id ], unique: true,
      name: "index_layered_verification_finding_observations_unique"

    safety_assured do
      %i[layered_verification_findings layered_verification_finding_observations].each do |table|
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      end

      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_findings
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM projects WHERE projects.id = layered_verification_findings.project_id
          AND projects.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM projects WHERE projects.id = layered_verification_findings.project_id
          AND projects.account_id = paid_current_account_id()
        ))
      SQL
      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_finding_observations
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM layered_verification_findings f INNER JOIN projects p ON p.id = f.project_id
          WHERE f.id = layered_verification_finding_observations.finding_id AND p.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM layered_verification_findings f INNER JOIN projects p ON p.id = f.project_id
          WHERE f.id = layered_verification_finding_observations.finding_id AND p.account_id = paid_current_account_id()
        ))
      SQL
    end
  end
end
