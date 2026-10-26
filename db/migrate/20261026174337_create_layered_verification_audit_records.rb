# frozen_string_literal: true

class CreateLayeredVerificationAuditRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :nullify }
      t.references :originating_audit_run, null: false, foreign_key: { to_table: :agent_runs, on_delete: :restrict }
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.text :source_passages, null: false
      t.text :observed_behavior, null: false
      t.text :decision_question, null: false
      t.jsonb :options, null: false, default: []
      t.text :deferred_reason
      t.timestamps
    end
    add_index :layered_verification_findings, [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ], unique: true, name: "index_layered_verification_findings_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, null: false, foreign_key: { to_table: :layered_verification_check_results, on_delete: :restrict }
      t.references :agent_run, null: false, foreign_key: true
      t.text :limitations, null: false
      t.timestamps
    end
    add_index :layered_verification_finding_observations, [ :finding_id, :check_result_id ], unique: true, name: "index_layered_verification_finding_observations_result"

    create_table :layered_verification_review_packages do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :package_identity, null: false
      t.integer :revision, null: false, default: 1
      t.jsonb :bound_inputs, null: false, default: {}
      t.timestamps
    end
    add_index :layered_verification_review_packages, [ :project_id, :package_identity, :revision ], unique: true, name: "index_layered_verification_review_packages_identity"
    enable_rls
  end

  private

  # These records are project-scoped evidence. PostgreSQL policy DDL has no
  # Rails helper, so keep the tenancy boundary explicit beside the tables.
  def enable_rls
    safety_assured do
      %i[layered_verification_findings layered_verification_finding_observations layered_verification_review_packages].each do |table|
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      end

      create_project_policy("layered_verification_findings", "layered_verification_findings.project_id")
      create_project_policy("layered_verification_review_packages", "layered_verification_review_packages.project_id")
      create_project_policy(
        "layered_verification_finding_observations",
        "(SELECT project_id FROM layered_verification_findings WHERE id = layered_verification_finding_observations.finding_id)"
      )
    end
  end

  def create_project_policy(table, project_expression)
    execute <<~SQL
      CREATE POLICY tenant_isolation ON #{table}
      AS PERMISSIVE FOR ALL
      USING (paid_tenant_bypass() OR #{project_expression} IN (SELECT id FROM projects WHERE account_id = paid_current_account_id()))
      WITH CHECK (paid_tenant_bypass() OR #{project_expression} IN (SELECT id FROM projects WHERE account_id = paid_current_account_id()))
    SQL
  end
end
