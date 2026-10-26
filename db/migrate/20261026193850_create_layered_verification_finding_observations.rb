# frozen_string_literal: true

class CreateLayeredVerificationFindingObservations < ActiveRecord::Migration[8.1]
  def up
    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, null: false, foreign_key: { to_table: :layered_verification_check_results, on_delete: :restrict }
      t.references :agent_run, null: false, foreign_key: { on_delete: :restrict }
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end

    add_index :layered_verification_finding_observations,
      [ :finding_id, :check_result_id ],
      unique: true,
      name: "index_layered_verification_finding_observations_evidence"
    enable_rls
  end

  def down
    drop_table :layered_verification_finding_observations
  end

  private

  def enable_rls
    safety_assured do
      execute "ALTER TABLE layered_verification_finding_observations ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE layered_verification_finding_observations FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_finding_observations
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM layered_verification_findings f
          INNER JOIN projects ON projects.id = f.project_id
          WHERE f.id = layered_verification_finding_observations.finding_id
          AND projects.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM layered_verification_findings f
          INNER JOIN projects ON projects.id = f.project_id
          WHERE f.id = layered_verification_finding_observations.finding_id
          AND projects.account_id = paid_current_account_id()
        ))
      SQL
    end
  end
end
