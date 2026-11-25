# frozen_string_literal: true

class CreateRunnerAuthMaterializations < ActiveRecord::Migration[8.1]
  def change
    create_table :runner_auth_materializations,
      comment: "Trusted per-container provenance for managed rotating runner credential materialization." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.references :runner_credential, null: true, foreign_key: { on_delete: :nullify }
      t.string :runner_key, null: false, limit: 64
      t.string :auth_source, null: false, limit: 32
      t.string :container_id, null: false, limit: 128
      t.datetime :credential_updated_at
      t.datetime :materialized_at, null: false
      t.timestamps
    end

    add_index :runner_auth_materializations,
      [ :agent_run_id, :runner_key, :container_id ],
      unique: true,
      name: "idx_runner_auth_materializations_run_runner_container"

    reversible do |direction|
      direction.up do
        safety_assured do
          execute <<~SQL
            ALTER TABLE runner_auth_materializations ENABLE ROW LEVEL SECURITY;
            ALTER TABLE runner_auth_materializations FORCE ROW LEVEL SECURITY;
            CREATE POLICY tenant_isolation ON runner_auth_materializations
              USING (
                paid_tenant_bypass() OR EXISTS (
                  SELECT 1 FROM projects
                  WHERE projects.id = runner_auth_materializations.project_id
                    AND projects.account_id = paid_current_account_id()
                )
              )
              WITH CHECK (
                paid_tenant_bypass() OR EXISTS (
                  SELECT 1 FROM projects
                  WHERE projects.id = runner_auth_materializations.project_id
                    AND projects.account_id = paid_current_account_id()
                )
              );
          SQL
        end
      end

      direction.down do
        safety_assured do
          execute "DROP POLICY IF EXISTS tenant_isolation ON runner_auth_materializations"
          execute "ALTER TABLE runner_auth_materializations NO FORCE ROW LEVEL SECURITY"
          execute "ALTER TABLE runner_auth_materializations DISABLE ROW LEVEL SECURITY"
        end
      end
    end
  end
end
