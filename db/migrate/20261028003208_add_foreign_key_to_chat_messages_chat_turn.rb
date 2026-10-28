# frozen_string_literal: true

class AddForeignKeyToChatMessagesChatTurn < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_foreign_key :chat_messages, :chat_turns, validate: false
  end
end
