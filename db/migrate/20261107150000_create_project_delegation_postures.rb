# frozen_string_literal: true

# RDR-080 project delegation posture: one durable row per project recording
# how far Paid may take downstream delivery after intent settles. The
# monotonic revision is the admission-binding token — every posture write
# bumps it so in-flight delegated admissions fail their next boundary
# recheck instead of silently following a broadened or narrowed setting.
class CreateProjectDelegationPostures < ActiveRecord::Migration[8.1]
  def up
    create_table :project_delegation_postures do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true, index: false
      t.references :selected_by, foreign_key: { to_table: :users }
      t.references :held_by, foreign_key: { to_table: :users }
      t.string :level, null: false, default: "conservative"
      t.integer :revision, null: false, default: 1
      t.string :policy_signature, null: false, default: ""
      t.jsonb :enabled_action_classes, null: false, default: []
      t.datetime :selected_at
      t.datetime :held_at
      t.text :hold_reason
      t.timestamps
    end

    add_index :project_delegation_postures, :project_id, unique: true,
      name: "index_project_delegation_postures_on_project"
    add_index :project_delegation_postures, [ :account_id, :level ],
      name: "index_project_delegation_postures_on_account_and_level"

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :project_delegation_postures
  end

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE project_delegation_postures ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_postures FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_postures"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON project_delegation_postures
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_postures"
      execute "ALTER TABLE project_delegation_postures NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_postures DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def tenant_condition
    <<~SQL.squish
      project_delegation_postures.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = project_delegation_postures.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND (
        project_delegation_postures.selected_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = project_delegation_postures.selected_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
      AND (
        project_delegation_postures.held_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = project_delegation_postures.held_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
    SQL
  end
end
