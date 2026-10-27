# frozen_string_literal: true

module ChatSessions
  # Detects turns whose worker stopped without a terminal outcome. This is
  # deliberately detection-only: a stale checkpoint is not proof that replaying
  # a tool is safe, so recovery remains an explicit user action.
  class DetectStalledTurns
    STALL_THRESHOLD = 10.minutes

    def initialize(now: Time.current)
      @now = now
    end

    def self.call(...)
      new(...).call
    end

    # @spec CHAT-TURN-001 CHAT-TURN-002 CHAT-TURN-003
    def call
      ChatTurn.incomplete.inactive_before(now - STALL_THRESHOLD).find_each.count do |turn|
        mark_stalled(turn)
      end
    end

    private

    attr_reader :now

    def mark_stalled(turn)
      turn.with_lock do
        return false unless turn.streaming? && turn.last_activity_at < now - STALL_THRESHOLD
        return false if awaiting_known_progress?(turn.chat_session)

        turn.update!(status: "stalled", detected_stalled_at: now)
        create_notice(turn)
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id,
          chat_session_id: turn.chat_session_id, detected_at: now.iso8601)
        true
      end
    end

    def awaiting_known_progress?(chat_session)
      chat_session.messages.pending_tool_confirmations.exists? || chat_session.rate_limited_until&.future?
    end

    def create_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This turn stalled before the assistant produced a final response. Completed tool activity remains in the transcript; any unfinished work is unknown. Review the prior tool results and send a new message to continue. Actions that require confirmation have not been replayed.",
        metadata: { "chat_turn_stalled" => true, "chat_turn_id" => turn.id, "detected_at" => now.iso8601 }
      )
    end
  end
end
