# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns, comment: "Durable lifecycle and recovery audit for one accepted chat user turn" do |t|
      t.references :account, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.references :checkpoint_message, foreign_key: { to_table: :chat_messages }
      t.uuid :stream_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :stall_classification
      t.datetime :last_activity_at, null: false
      t.datetime :detected_at
      t.datetime :completed_at
      t.integer :recovery_attempts, null: false, default: 0
      t.string :recovery_outcome
      t.references :recovered_by, foreign_key: { to_table: :users }
      t.boolean :side_effects_completed, null: false, default: false
      t.integer :lock_version, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :stream_id, unique: true
    add_index :chat_turns, [ :status, :last_activity_at ]
    add_index :chat_turns, [ :chat_session_id, :created_at ]
  end
end
