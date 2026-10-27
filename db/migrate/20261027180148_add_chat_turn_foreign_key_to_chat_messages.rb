class AddChatTurnForeignKeyToChatMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_reference :chat_messages, :chat_turn, index: { algorithm: :concurrently }
  end

  def down
    remove_reference :chat_messages, :chat_turn, index: { algorithm: :concurrently }
  end
end
