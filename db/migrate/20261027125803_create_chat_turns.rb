class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.datetime :activity_at, null: false
      t.datetime :detected_at
      t.datetime :recovery_started_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :chat_turns, :user_message_id, unique: true
    add_index :chat_turns, [ :status, :activity_at ]
  end
end
