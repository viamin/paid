# frozen_string_literal: true

module ChatSessions
  class StallTurn
    attr_reader :turn

    def initialize(turn:)
      @turn = turn
    end

    def self.call(...)
      new(...).call
    end

    def call
      turn.with_lock do
        return false unless turn.reload.status.in?(%w[pending streaming])
        return false if turn.awaiting_confirmation? || turn.rate_limited?

        turn.stalled!(classification: "inactivity_timeout")
        persist_notice
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id)
        true
      end
    end

    private

    def persist_notice
      turn.chat_session.messages.create!(
        role: "system",
        content: "This chat request did not finish after its last recorded activity. Earlier messages and tool results are preserved, but the final response is unknown. Review the transcript, then choose Resume to continue safely.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id }
      )
    end
  end
end
