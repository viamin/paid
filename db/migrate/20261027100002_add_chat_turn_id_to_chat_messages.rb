# frozen_string_literal: true

# @spec CHAT-TURN-LIFECYCLE-001 @spec CHAT-TURN-LIFECYCLE-008
class AddChatTurnIdToChatMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :chat_messages, :chat_turn, index: { algorithm: :concurrently }
  end
end
