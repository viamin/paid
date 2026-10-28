class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "pending"
      t.uuid :stream_message_id
      t.datetime :last_activity_at, null: false
      t.datetime :completed_at
      t.datetime :stalled_at
      t.string :failure_classification
      t.integer :recovery_attempts, null: false, default: 0
      t.boolean :side_effecting_tool_completed, null: false, default: false
      t.jsonb :metadata, null: false, default: {}
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end
    add_index :chat_turns, :stream_message_id, unique: true
    add_index :chat_turns, [ :status, :last_activity_at ]
  end
end
