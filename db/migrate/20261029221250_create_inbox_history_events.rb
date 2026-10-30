# frozen_string_literal: true

class CreateInboxHistoryEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :inbox_history_events do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.string :subject_key, null: false
      t.string :event_key, null: false
      t.datetime :occurred_at, null: false
      t.string :actor_label, null: false
      t.string :source, null: false
      t.string :result, null: false
      t.string :revision
      t.string :evidence_url
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :inbox_history_events, %i[account_id subject_key occurred_at], name: "index_inbox_history_events_subject_time"
    add_index :inbox_history_events, %i[account_id subject_key event_key], unique: true,
      name: "index_inbox_history_events_dedup"

    # The row carries both account_id and project_id; validate both so a write
    # under tenant A cannot associate a project owned by tenant B. Requiring the
    # referenced project's account to match the current tenant (and the row's
    # own account_id) keeps the two independent foreign keys from admitting a
    # cross-tenant association, matching the project-backed RLS policies.
    safety_assured do
      execute <<~SQL
        ALTER TABLE inbox_history_events ENABLE ROW LEVEL SECURITY;
        ALTER TABLE inbox_history_events FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON inbox_history_events
          USING (
            paid_tenant_bypass() OR (
              account_id = paid_current_account_id()
              AND EXISTS (
                SELECT 1 FROM projects
                WHERE projects.id = inbox_history_events.project_id
                  AND projects.account_id = paid_current_account_id()
              )
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR (
              account_id = paid_current_account_id()
              AND EXISTS (
                SELECT 1 FROM projects
                WHERE projects.id = inbox_history_events.project_id
                  AND projects.account_id = paid_current_account_id()
              )
            )
          );
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON inbox_history_events" }
    safety_assured { execute "ALTER TABLE inbox_history_events NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE inbox_history_events DISABLE ROW LEVEL SECURITY" }
    drop_table :inbox_history_events
  end
end
