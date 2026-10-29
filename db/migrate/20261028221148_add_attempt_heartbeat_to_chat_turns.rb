# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-001 @spec CHAT-TURN-RECOVERY-002
class AddAttemptHeartbeatToChatTurns < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_turns, :attempt_heartbeat_at, :datetime,
      comment: "Throttled durable liveness lease for the currently executing provider loop."
  end
end
