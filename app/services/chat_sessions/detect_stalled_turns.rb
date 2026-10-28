# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurns
    def self.call(...)
      new(...).call
    end

    def call
      ChatTurn.watchdog_candidates.find_each.filter_map do |turn|
        next unless turn.stall!

        persist_notice(turn)
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id)
        turn
      end
    end

    private

    def persist_notice(turn)
      turn.chat_session.messages.create!(role: "system", chat_turn: turn,
        content: "This turn stopped without a final assistant response. Completed transcript activity is preserved; do not assume an unfinished tool ran. Review any pending confirmation before retrying.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "detected_at" => turn.stalled_at.iso8601 })
    end
  end
end
