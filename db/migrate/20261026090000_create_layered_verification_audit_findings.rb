# frozen_string_literal: true

# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017
class CreateLayeredVerificationAuditFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :nullify }
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :state, null: false, default: "open"
      t.text :deferral_reason
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true, name: "index_layered_verification_findings_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :agent_run, foreign_key: { on_delete: :nullify }
      t.references :check_result, foreign_key: { to_table: :layered_verification_check_results, on_delete: :nullify }
      t.jsonb :source_passages, null: false, default: {}
      t.text :observed_behavior, null: false
      t.text :limitations, null: false
      t.timestamps
    end

    enable_rls
  end

  private

  # RLS has no Rails migration helper. Findings are project-scoped directly;
  # observations inherit their tenant boundary through their finding.
  def enable_rls
    safety_assured do
      execute "ALTER TABLE layered_verification_findings ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE layered_verification_findings FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE layered_verification_finding_observations ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE layered_verification_finding_observations FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_findings AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM projects WHERE projects.id = layered_verification_findings.project_id
          AND projects.account_id = paid_current_account_id()
        )) WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM projects WHERE projects.id = layered_verification_findings.project_id
          AND projects.account_id = paid_current_account_id()
        ))
      SQL
      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_finding_observations AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM layered_verification_findings INNER JOIN projects ON projects.id = layered_verification_findings.project_id
          WHERE layered_verification_findings.id = layered_verification_finding_observations.finding_id
          AND projects.account_id = paid_current_account_id()
        )) WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM layered_verification_findings INNER JOIN projects ON projects.id = layered_verification_findings.project_id
          WHERE layered_verification_findings.id = layered_verification_finding_observations.finding_id
          AND projects.account_id = paid_current_account_id()
        ))
      SQL
    end
  end
end
