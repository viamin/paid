# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-007
class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns, comment: "Durable lifecycle and recovery checkpoint for one user-initiated chat turn." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: true, foreign_key: {to_table: :chat_messages}
      t.references :initiated_by, null: true, foreign_key: {to_table: :users}
      t.string :stream_message_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :classification
      t.string :pause_reason
      t.datetime :last_activity_at, null: false
      t.datetime :detected_stalled_at
      t.datetime :completed_at
      t.boolean :side_effects_completed, null: false, default: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :chat_turns, [:chat_session_id, :stream_message_id], unique: true
    add_index :chat_turns, [:account_id, :status, :last_activity_at]
    add_index :chat_turns, [:status, :last_activity_at]

    safety_assured do
      execute "ALTER TABLE chat_turns ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE chat_turns FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON chat_turns
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
        WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id())
      SQL
    end
  end
end
