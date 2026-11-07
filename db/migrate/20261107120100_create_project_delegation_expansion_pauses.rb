# frozen_string_literal: true

# @spec PROJECT-DELEGATION-007
class CreateProjectDelegationExpansionPauses < ActiveRecord::Migration[8.1]
  def up
    create_table :project_delegation_expansion_pauses do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.string :reason, null: false
      t.string :posture_before, null: false, default: "conservative"
      t.text :detail
      t.jsonb :evidence, null: false, default: {}
      t.references :paused_by, foreign_key: { to_table: :users }
      t.datetime :resolved_at
      t.references :resolved_by, foreign_key: { to_table: :users }
      t.text :resolution_note
      t.timestamps
    end

    add_index :project_delegation_expansion_pauses, [ :project_id, :resolved_at ],
      name: "index_expansion_pauses_on_project_unresolved",
      where: "resolved_at IS NULL"

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :project_delegation_expansion_pauses
  end

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE project_delegation_expansion_pauses ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_expansion_pauses FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_expansion_pauses"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON project_delegation_expansion_pauses
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_expansion_pauses"
      execute "ALTER TABLE project_delegation_expansion_pauses NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_expansion_pauses DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def tenant_condition
    <<~SQL.squish
      project_delegation_expansion_pauses.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = project_delegation_expansion_pauses.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND (
        project_delegation_expansion_pauses.paused_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = project_delegation_expansion_pauses.paused_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
      AND (
        project_delegation_expansion_pauses.resolved_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = project_delegation_expansion_pauses.resolved_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
    SQL
  end
end
