# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurns
    def initialize(now: Time.current)
      @now = now
    end

    def self.call(...)
      new(...).call
    end

    def call
      ChatTurn.stale_before(now - ChatTurn::STALL_TIMEOUT).find_each do |turn|
        classify!(turn)
      end
    end

    private

    attr_reader :now

    # @spec CHAT-TURN-001 CHAT-TURN-002 CHAT-TURN-003 CHAT-TURN-007
    def classify!(turn)
      turn.with_lock do
        return unless turn.stall_eligible?(at: now)

        turn.update!(status: "stalled", classification: "unknown_inactivity", detected_at: now, last_activity_at: now)
        persist_notice(turn)
        audit(turn, "stalled")
      end
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This chat turn needs attention. Some activity may have completed, but no final assistant response was recorded. Review the preserved tool activity before retrying.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "classification" => turn.classification }
      )
    end

    def audit(turn, outcome)
      Rails.logger.warn(message: "chat_turn.classified", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
        classification: turn.classification, outcome: outcome, side_effecting_tools_completed: !turn.replay_safe?)
    end
  end
end
