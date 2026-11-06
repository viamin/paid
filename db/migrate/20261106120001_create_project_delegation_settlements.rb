# frozen_string_literal: true

# @spec PROJECT-DELEGATION-002
class CreateProjectDelegationSettlements < ActiveRecord::Migration[8.1]
  def up
    create_table :project_delegation_settlements do |t|
      t.references :checkpoint, null: false,
        foreign_key: { to_table: :project_delegation_checkpoints }
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :settled_by, null: false, foreign_key: { to_table: :users }
      t.string :decision, null: false
      t.jsonb :answers, null: false, default: []
      t.string :design_revision, null: false
      t.string :acceptance_revision, null: false
      t.timestamps
    end

    add_index :project_delegation_settlements, %i[checkpoint_id id],
      name: "index_delegation_settlements_on_checkpoint_and_id"

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :project_delegation_settlements
  end

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE project_delegation_settlements ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_settlements FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_settlements"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON project_delegation_settlements
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_settlements"
      execute "ALTER TABLE project_delegation_settlements NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_settlements DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def tenant_condition
    <<~SQL.squish
      project_delegation_settlements.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = project_delegation_settlements.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND EXISTS (
        SELECT 1 FROM project_delegation_checkpoints
        WHERE project_delegation_checkpoints.id = project_delegation_settlements.checkpoint_id
          AND project_delegation_checkpoints.project_id = project_delegation_settlements.project_id
          AND project_delegation_checkpoints.account_id = paid_current_account_id()
      )
      AND EXISTS (
        SELECT 1 FROM users
        WHERE users.id = project_delegation_settlements.settled_by_id
          AND users.account_id = paid_current_account_id()
      )
    SQL
  end
end
