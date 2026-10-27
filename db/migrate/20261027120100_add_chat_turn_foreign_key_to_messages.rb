# frozen_string_literal: true

class AddChatTurnForeignKeyToMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_foreign_key :chat_messages, :chat_turns, validate: false
    validate_foreign_key :chat_messages, :chat_turns
  end
end
