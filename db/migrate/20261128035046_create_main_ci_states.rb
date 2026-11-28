# frozen_string_literal: true

class CreateMainCiStates < ActiveRecord::Migration[8.1]
  def change
    create_table :main_ci_states do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      t.references :repair_run, foreign_key: { to_table: :agent_runs }, index: true
      t.string :status, null: false, default: "unverified"
      t.string :verified_sha, limit: 40
      t.string :observed_sha, limit: 40
      t.string :failed_sha, limit: 40
      t.string :episode_key, limit: 36
      t.integer :dispatch_count, null: false, default: 0
      t.jsonb :evidence, null: false, default: {}, comment: "Redacted main-CI failure and complete verified-baseline provenance."
      t.datetime :failed_at
      t.datetime :dispatched_at
      t.datetime :verified_at
      t.timestamps
    end

    reversible do |direction|
      direction.up do
        safety_assured do
          execute "ALTER TABLE main_ci_states ENABLE ROW LEVEL SECURITY"
          execute "ALTER TABLE main_ci_states FORCE ROW LEVEL SECURITY"
          execute <<~SQL
            CREATE POLICY tenant_isolation ON main_ci_states
            FOR ALL USING (
              paid_tenant_bypass() OR (
                account_id = paid_current_account_id() AND EXISTS (
                  SELECT 1 FROM projects WHERE projects.id = main_ci_states.project_id
                    AND projects.account_id = main_ci_states.account_id
                ) AND (repair_run_id IS NULL OR EXISTS (
                  SELECT 1 FROM agent_runs WHERE agent_runs.id = main_ci_states.repair_run_id
                    AND agent_runs.project_id = main_ci_states.project_id
                ))
              )
            ) WITH CHECK (
              paid_tenant_bypass() OR (
                account_id = paid_current_account_id() AND EXISTS (
                  SELECT 1 FROM projects WHERE projects.id = main_ci_states.project_id
                    AND projects.account_id = main_ci_states.account_id
                ) AND (repair_run_id IS NULL OR EXISTS (
                  SELECT 1 FROM agent_runs WHERE agent_runs.id = main_ci_states.repair_run_id
                    AND agent_runs.project_id = main_ci_states.project_id
                ))
              )
            )
          SQL
        end
      end
    end
  end
end
