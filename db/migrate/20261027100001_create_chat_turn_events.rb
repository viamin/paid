# frozen_string_literal: true

# @spec CHAT-TURN-LIFECYCLE-011
class CreateChatTurnEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turn_events do |t|
      t.references :chat_turn, null: false, foreign_key: { on_delete: :cascade }
      t.references :chat_session, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.string :event_type, null: false
      t.string :classification
      t.string :recovery_state
      t.string :user_action
      t.boolean :side_effecting_tools_completed, null: false, default: false
      t.bigint :actor_id
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :chat_turn_events, [ :event_type, :created_at ]
    add_index :chat_turn_events, [ :chat_turn_id, :created_at ]

    safety_assured do
      execute "ALTER TABLE chat_turn_events ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE chat_turn_events FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON chat_turn_events
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR chat_turn_events.account_id = paid_current_account_id())
        WITH CHECK (paid_tenant_bypass() OR chat_turn_events.account_id = paid_current_account_id())
      SQL
    end
  end
end
