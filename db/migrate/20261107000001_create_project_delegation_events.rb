# frozen_string_literal: true

class CreateProjectDelegationEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :project_delegation_events do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :action, null: false, comment: "Event action type: posture_selected, etc."
      t.string :posture, null: false, comment: "The posture selected or changed"
      t.string :policy_signature, comment: "Policy signature at the time of the event"
      t.jsonb :metadata, default: {}, null: false, comment: "Structured event details"
      t.timestamps
    end

    add_index :project_delegation_events, [ :project_id, :created_at ],
      name: "index_project_delegation_events_on_project_and_created_at"
    add_index :project_delegation_events, [ :account_id, :created_at ],
      name: "index_project_delegation_events_on_account_and_created_at"
    add_index :project_delegation_events, :action

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :project_delegation_events
  end

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE project_delegation_events ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_events FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_events"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON project_delegation_events
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_events"
      execute "ALTER TABLE project_delegation_events NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_events DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def tenant_condition
    <<~SQL.squish
      project_delegation_events.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = project_delegation_events.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND (
        project_delegation_events.actor_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = project_delegation_events.actor_id
            AND users.account_id = paid_current_account_id()
        )
      )
    SQL
  end
end
