# frozen_string_literal: true

# @spec CHAT-TURN-LIFECYCLE-001 @spec CHAT-TURN-LIFECYCLE-003
class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :user_message_id
      t.bigint :assistant_message_id
      t.string :status, null: false, default: "pending"
      t.string :classification
      t.string :recovery_state, null: false, default: "none"
      t.integer :recovery_attempts, null: false, default: 0
      t.bigint :recovery_requested_by_id
      t.datetime :recovery_requested_at
      t.datetime :last_activity_at, null: false
      t.datetime :detected_at
      t.datetime :stalled_at
      t.datetime :completed_at
      t.bigint :checkpoint_message_id
      t.boolean :side_effecting_tools_completed, null: false, default: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :status, :last_activity_at ]
    add_index :chat_turns, [ :chat_session_id, :created_at ]
    add_index :chat_turns, :user_message_id
    add_index :chat_turns, :checkpoint_message_id

    safety_assured do
      execute "ALTER TABLE chat_turns ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE chat_turns FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON chat_turns
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR chat_turns.account_id = paid_current_account_id())
        WITH CHECK (paid_tenant_bypass() OR chat_turns.account_id = paid_current_account_id())
      SQL
    end
  end
end
