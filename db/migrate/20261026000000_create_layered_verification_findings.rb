# frozen_string_literal: true

class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  def up
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :restrict }
      t.references :originating_audit_run, null: false, foreign_key: { to_table: :agent_runs, on_delete: :restrict }
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :detail, null: false, default: {}
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true, name: "index_layered_verification_findings_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, null: false, foreign_key: { to_table: :layered_verification_check_results, on_delete: :restrict }
      t.references :agent_run, null: false, foreign_key: { on_delete: :restrict }
      t.jsonb :detail, null: false, default: {}
      t.timestamps
    end

    add_index :layered_verification_finding_observations,
      [ :finding_id, :check_result_id ], unique: true, name: "index_layered_verification_finding_observations_unique"

    enable_rls
  end

  def down
    safety_assured do
      drop_table :layered_verification_finding_observations
      drop_table :layered_verification_findings
    end
  end

  private

  def enable_rls
    safety_assured do
      %i[layered_verification_findings layered_verification_finding_observations].each do |table|
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      end

      execute policy_sql("layered_verification_findings", <<~SQL)
        EXISTS (SELECT 1 FROM projects WHERE projects.id = layered_verification_findings.project_id
          AND projects.account_id = paid_current_account_id())
      SQL
      execute policy_sql("layered_verification_finding_observations", <<~SQL)
        EXISTS (
          SELECT 1 FROM layered_verification_findings f
          INNER JOIN projects ON projects.id = f.project_id
          WHERE f.id = layered_verification_finding_observations.finding_id
            AND projects.account_id = paid_current_account_id()
        )
      SQL
    end
  end

  def policy_sql(table, condition)
    <<~SQL
      CREATE POLICY tenant_isolation ON #{table} AS PERMISSIVE FOR ALL
      USING (paid_tenant_bypass() OR (#{condition}))
      WITH CHECK (paid_tenant_bypass() OR (#{condition}))
    SQL
  end
end
