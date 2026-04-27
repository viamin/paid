# frozen_string_literal: true

class CreateChatMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_messages do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.uuid :external_id, null: false, default: -> { "gen_random_uuid()" }
      t.string :role, null: false
      t.text :content
      t.string :tool_call_id
      t.string :tool_name
      t.jsonb :tool_arguments
      t.jsonb :tool_result
      t.string :model
      t.integer :tokens_input
      t.integer :tokens_output
      t.jsonb :metadata, default: {}
      t.timestamps
    end

    add_index :chat_messages, :external_id, unique: true
    add_index :chat_messages, [ :chat_session_id, :created_at ]
    add_index :chat_messages, :role
  end
end
