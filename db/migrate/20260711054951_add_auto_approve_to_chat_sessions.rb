# frozen_string_literal: true

class AddAutoApproveToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_sessions, :auto_approve, :boolean, null: false, default: false,
      comment: "When true, write tool calls (e.g. agent run creation) are auto-approved without a manual confirmation click"
  end
end
