# frozen_string_literal: true

class AddToolStatusToChatMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :chat_messages, :tool_status, :string,
      comment: "Confirmation state for write tool calls: pending, approved, or denied"

    add_index :chat_messages, :tool_status, algorithm: :concurrently, where: "tool_status = 'pending'"
  end
end
