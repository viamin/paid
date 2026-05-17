# frozen_string_literal: true

class CreateExceptionIncidents < ActiveRecord::Migration[8.1]
  def up
    create_table :exception_incidents do |t|
      t.bigint :account_id, null: false
      t.bigint :project_id
      t.string :fingerprint, null: false
      t.string :exception_class, null: false
      t.text :message, null: false
      t.text :backtrace
      t.string :subsystem, null: false
      t.string :severity, null: false, default: "p2"
      t.string :action_taken, null: false, default: "logged"
      t.string :status, null: false, default: "open"
      t.string :github_issue_url
      t.integer :github_issue_number
      t.integer :occurrence_count, null: false, default: 1
      t.jsonb :context, null: false, default: {}
      t.datetime :last_occurred_at, null: false
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :exception_incidents, [ :account_id, :fingerprint ],
      unique: true, name: "index_exception_incidents_on_dedup"
    add_index :exception_incidents, [ :account_id, :status ], name: "index_exception_incidents_on_status"
    add_index :exception_incidents, [ :account_id, :subsystem ], name: "index_exception_incidents_on_subsystem"
    add_index :exception_incidents, [ :project_id ], name: "index_exception_incidents_on_project"
    add_index :exception_incidents, [ :severity ], name: "index_exception_incidents_on_severity"

    add_foreign_key :exception_incidents, :accounts
    add_foreign_key :exception_incidents, :projects

    safety_assured do
      execute <<~SQL
        ALTER TABLE exception_incidents ENABLE ROW LEVEL SECURITY;
        ALTER TABLE exception_incidents FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON exception_incidents
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON exception_incidents" }
    safety_assured { execute "ALTER TABLE exception_incidents NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE exception_incidents DISABLE ROW LEVEL SECURITY" }

    drop_table :exception_incidents
  end
end
