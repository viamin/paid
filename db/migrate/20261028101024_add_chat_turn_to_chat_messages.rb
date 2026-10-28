# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-001
class AddChatTurnToChatMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_reference :chat_messages, :chat_turn, index: {algorithm: :concurrently},
      comment: "Turn whose durable transcript evidence includes this message."
    add_foreign_key :chat_messages, :chat_turns, validate: false
    validate_foreign_key :chat_messages, :chat_turns
  end

  def down
    remove_reference :chat_messages, :chat_turn, foreign_key: true
  end
end
