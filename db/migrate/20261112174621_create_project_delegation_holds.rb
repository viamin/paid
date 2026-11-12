# frozen_string_literal: true

# RDR-080 / PROJECT-DELEGATION-010: the durable explicit hold on delegated
# work. One row records who placed the hold, why, and when it was released.
# The hold pauses the next delegated action for the project without changing
# the posture, the admission snapshots, or the delegated evidence, and it is
# released by an authorized actor rather than by a posture change.
class CreateProjectDelegationHolds < ActiveRecord::Migration[8.1]
  def up
    create_table :project_delegation_holds do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: { to_table: :projects }
      t.references :held_by, foreign_key: { to_table: :users }
      t.references :released_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "held"
      t.text :reason, null: false
      t.datetime :held_at, null: false
      t.datetime :released_at
      t.timestamps
    end

    add_index :project_delegation_holds, [ :project_id ], unique: true,
      where: "status = 'held'", name: "index_project_delegation_holds_on_active_project"

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :project_delegation_holds
  end

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE project_delegation_holds ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_holds FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_holds"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON project_delegation_holds
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_holds"
      execute "ALTER TABLE project_delegation_holds NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_holds DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def tenant_condition
    <<~SQL.squish
      project_delegation_holds.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = project_delegation_holds.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND (
        project_delegation_holds.held_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = project_delegation_holds.held_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
      AND (
        project_delegation_holds.released_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = project_delegation_holds.released_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
    SQL
  end
end
