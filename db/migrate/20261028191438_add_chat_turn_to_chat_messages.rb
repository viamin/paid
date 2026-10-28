class AddChatTurnToChatMessages < ActiveRecord::Migration[8.1]
  def change
    add_reference :chat_messages, :chat_turn, foreign_key: true
  end
end
