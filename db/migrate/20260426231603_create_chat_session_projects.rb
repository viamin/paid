# frozen_string_literal: true

class CreateChatSessionProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_session_projects do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.string :context_type, null: false, default: "reference"
      t.timestamps
    end

    add_index :chat_session_projects, [ :chat_session_id, :project_id ], unique: true
  end
end
