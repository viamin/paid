# frozen_string_literal: true

# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017 @spec LAYERED-VERIFY-024
class CreateLayeredVerificationAuditFindings < ActiveRecord::Migration[8.1]
  def up
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: true
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :source_passages, null: false, default: []
      t.jsonb :claims, null: false, default: []
      t.text :observed_behavior, null: false
      t.text :question, null: false
      t.jsonb :options, null: false, default: []
      t.jsonb :consequences, null: false, default: []
      t.jsonb :owner_actions, null: false, default: []
      t.text :deferred_reason
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true,
      name: "index_layered_verification_findings_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, null: false, foreign_key: { to_table: :layered_verification_check_results, on_delete: :restrict }
      t.references :agent_run, null: false, foreign_key: true
      t.jsonb :provenance, null: false, default: {}
      t.timestamps
    end

    add_index :layered_verification_finding_observations,
      [ :finding_id, :check_result_id ], unique: true,
      name: "index_layered_verification_finding_observations_unique"

    enable_rls
  end

  def down
    drop_table :layered_verification_finding_observations
    drop_table :layered_verification_findings
  end

  private

  def enable_rls
    safety_assured do
      %i[layered_verification_findings layered_verification_finding_observations].each do |table|
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      end

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

      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_finding_observations
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM layered_verification_findings findings
          INNER JOIN projects ON projects.id = findings.project_id
          WHERE findings.id = layered_verification_finding_observations.finding_id
            AND projects.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM layered_verification_findings findings
          INNER JOIN projects ON projects.id = findings.project_id
          WHERE findings.id = layered_verification_finding_observations.finding_id
            AND projects.account_id = paid_current_account_id()
        ))
      SQL
    end
  end
end
