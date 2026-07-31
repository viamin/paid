# frozen_string_literal: true

class DropModeFromChatSessions < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:chat_sessions)
    return unless column_exists?(:chat_sessions, :mode)

    safety_assured { remove_column :chat_sessions, :mode, :string }
  end

  def down
    return unless table_exists?(:chat_sessions)
    return if column_exists?(:chat_sessions, :mode)

    add_column :chat_sessions, :mode, :string, default: "api", null: false

    safety_assured do
      execute <<~SQL.squish
        UPDATE chat_sessions
        SET mode = CASE
          WHEN container_capability = 'none' THEN 'api'
          ELSE 'workspace'
        END
      SQL
    end
  end
end
