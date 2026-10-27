# frozen_string_literal: true

class ValidateChatTurnForeignKeyOnChatMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    validate_foreign_key :chat_messages, :chat_turns
  end
end
