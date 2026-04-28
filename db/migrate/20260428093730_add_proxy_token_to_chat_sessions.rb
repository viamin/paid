# frozen_string_literal: true

class AddProxyTokenToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_sessions, :proxy_token, :string, limit: 64
    add_index :chat_sessions, :proxy_token, unique: true
  end
end
