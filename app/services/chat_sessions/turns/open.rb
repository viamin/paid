# frozen_string_literal: true

module ChatSessions
  module Turns
    class Open
      # @spec CHAT-TURN-RECOVERY-001
      def self.call(chat_session:, user_message:)
        turn = ChatTurn.find_or_initialize_by(chat_session:, user_message:)
        return turn if turn.persisted?

        turn.assign_attributes(status: "pending", started_at: Time.current, last_activity_at: Time.current)
        turn.save!
        turn
      end
    end
  end
end
