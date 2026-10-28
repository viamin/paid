# frozen_string_literal: true

class AddChatTurnToChatMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :chat_messages, :chat_turn, index: false,
      comment: "Turn that durably produced this transcript row."
    add_index :chat_messages, :chat_turn_id, algorithm: :concurrently
  end
end
