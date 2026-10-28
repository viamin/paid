# frozen_string_literal: true

module ChatTurns
  class Complete
    # @spec CHAT-TURN-RECOVERY-002
    def self.call(chat_turn:)
      chat_turn.update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
    end
  end
end
