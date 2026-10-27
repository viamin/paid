class AddForeignKeyToChatMessagesChatTurn < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_foreign_key :chat_messages, :chat_turns, validate: false unless foreign_key_exists?(:chat_messages, :chat_turns)
    validate_foreign_key :chat_messages, :chat_turns
  end

  def down
    remove_foreign_key :chat_messages, :chat_turns if foreign_key_exists?(:chat_messages, :chat_turns)
  end
end
