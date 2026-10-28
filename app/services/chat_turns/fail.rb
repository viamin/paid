# frozen_string_literal: true

module ChatTurns
  class Fail
    # @spec CHAT-TURN-RECOVERY-001
    def self.call(classification:, chat_turn: nil, chat_session_id: nil, stream_message_id: nil)
      turn = chat_turn || find_turn(chat_session_id, stream_message_id)
      turn&.update!(
        status: "failed",
        failure_classification: classification,
        completed_at: Time.current,
        last_activity_at: Time.current
      )
    end

    def self.find_turn(chat_session_id, stream_message_id)
      return if stream_message_id.blank?

      ChatTurn.find_by(chat_session_id:, stream_message_id:)
    end
    private_class_method :find_turn
  end
end
