# frozen_string_literal: true

class AddRateLimitedUntilToChatSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    return unless table_exists?(:chat_sessions)

    unless column_exists?(:chat_sessions, :rate_limited_until)
      add_column :chat_sessions, :rate_limited_until, :datetime,
        comment: "When a runner rate limit that paused this chat session is expected to clear. Set when a chat turn " \
          "exhausts every fallback runner with an AgentHarness::RateLimitError; cleared on a successful resend."
    end

    add_index :chat_sessions, :rate_limited_until, algorithm: :concurrently, if_not_exists: true
  end

  def down
    return unless table_exists?(:chat_sessions)

    remove_index :chat_sessions, :rate_limited_until, algorithm: :concurrently, if_exists: true
    remove_column :chat_sessions, :rate_limited_until if column_exists?(:chat_sessions, :rate_limited_until)
  end
end
