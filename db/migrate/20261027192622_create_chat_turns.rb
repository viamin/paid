class CreateChatTurns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.references :terminal_message, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending"
      t.string :classification
      t.datetime :last_activity_at, null: false
      t.datetime :detection_at
      t.datetime :completed_at
      t.datetime :recovery_requested_at
      t.bigint :recovery_requested_by_id
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :status, :last_activity_at ]
    add_reference :chat_messages, :chat_turn, index: { algorithm: :concurrently }
  end
end
