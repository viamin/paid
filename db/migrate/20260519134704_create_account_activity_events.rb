# frozen_string_literal: true

class CreateAccountActivityEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :account_activity_events do |t|
      t.references :account, null: false, foreign_key: true, index: false,
        comment: "Account whose administration history this event belongs to."
      t.bigint :actor_id, comment: "User who performed the action, when available."
      t.string :action, null: false, comment: "Stable action key for the account administration event."
      t.string :subject_type, comment: "Polymorphic subject type affected by the action."
      t.bigint :subject_id
      t.jsonb :metadata, null: false, default: {}, comment: "Structured event details for UI rendering and audits."

      t.timestamps
    end

    add_foreign_key :account_activity_events, :users, column: :actor_id, validate: false
    add_index :account_activity_events, :actor_id
    add_index :account_activity_events, [ :account_id, :created_at ]
    add_index :account_activity_events, [ :subject_type, :subject_id ]

    execute <<~SQL
      ALTER TABLE account_activity_events ENABLE ROW LEVEL SECURITY;
      ALTER TABLE account_activity_events FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON account_activity_events
        USING (account_id = paid_current_account_id())
        WITH CHECK (account_id = paid_current_account_id());
    SQL
  end

  def down
    return unless table_exists?(:account_activity_events)

    execute "DROP POLICY IF EXISTS tenant_isolation ON account_activity_events"
    execute "ALTER TABLE account_activity_events NO FORCE ROW LEVEL SECURITY"
    remove_index :account_activity_events, [ :subject_type, :subject_id ], if_exists: true
    remove_index :account_activity_events, [ :account_id, :created_at ], if_exists: true
    remove_index :account_activity_events, :actor_id, if_exists: true
    remove_foreign_key :account_activity_events, column: :actor_id if foreign_key_exists?(:account_activity_events, column: :actor_id)
    drop_table :account_activity_events, if_exists: true
  end
end
