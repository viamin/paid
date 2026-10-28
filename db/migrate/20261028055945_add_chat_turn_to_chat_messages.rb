# frozen_string_literal: true

class AddChatTurnToChatMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :chat_messages, :chat_turn, index: { algorithm: :concurrently }
  end
end
