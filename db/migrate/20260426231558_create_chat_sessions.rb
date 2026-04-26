# frozen_string_literal: true

class CreateChatSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_sessions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, foreign_key: true
      t.references :provider, foreign_key: true
      t.uuid :external_id, null: false, default: -> { "gen_random_uuid()" }
      t.string :status, null: false, default: "active"
      t.string :mode, null: false, default: "api"
      t.string :model
      t.text :system_prompt
      t.string :container_id
      t.string :workspace_volume
      t.jsonb :metadata, default: {}
      t.datetime :idle_timeout_at
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :title
      t.timestamps
    end

    add_index :chat_sessions, :external_id, unique: true
    add_index :chat_sessions, :status
    add_index :chat_sessions, :idle_timeout_at
  end
end
