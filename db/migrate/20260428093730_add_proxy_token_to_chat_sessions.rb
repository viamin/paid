# frozen_string_literal: true

class AddProxyTokenToChatSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :chat_sessions, :proxy_token, :string, limit: 64
    add_index :chat_sessions, :proxy_token, unique: true, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :chat_sessions, :proxy_token, algorithm: :concurrently, if_exists: true
    remove_column :chat_sessions, :proxy_token
  end
end
