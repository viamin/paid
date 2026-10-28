# frozen_string_literal: true

module ChatTurns
  class Stall
    # @spec CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-005
    def self.call(chat_turn:)
      new(chat_turn:).call
    end

    def initialize(chat_turn:)
      @chat_turn = chat_turn
    end

    def call
      chat_turn.with_lock do
        return false unless chat_turn.status.in?(ChatTurn::ACTIVE_STATUSES)

        chat_turn.update!(status: "stalled", stalled_at: Time.current)
        create_notice
        log_stall
        true
      end
    end

    private

    attr_reader :chat_turn

    def create_notice
      chat_turn.chat_session.messages.create!(
        role: "system",
        content: "This chat turn stopped making durable progress, and its completion is unknown. " \
          "Your messages and any completed tool activity are preserved. Review the transcript and any awaiting confirmation before retrying.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => chat_turn.id }
      )
    end

    def log_stall
      Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: chat_turn.id,
        chat_session_id: chat_turn.chat_session_id, last_activity_at: chat_turn.last_activity_at)
    end
  end
end
