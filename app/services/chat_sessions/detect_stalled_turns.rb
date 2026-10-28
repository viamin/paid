# frozen_string_literal: true

module ChatSessions
  # Converts only genuinely inactive, unfinished turns into a durable stalled
  # outcome. Confirmation pauses have their own lifecycle state and are never
  # candidates for this sweep.
  class DetectStalledTurns
    def self.call(...) = new(...).call

    def initialize(now: Time.current)
      @now = now
    end

    def call
      ChatTurn.overdue(now).find_each do |turn|
        turn.with_lock { stall(turn) }
      end
    end

    private

    attr_reader :now

    def stall(turn)
      return unless turn.status.in?(ChatTurn::ACTIVE_STATUSES)
      return unless turn.last_activity_at <= now - ChatTurn.stall_threshold
      return if turn.chat_session.rate_limited?

      turn.update!(status: "stalled", detected_at: now, last_activity_at: now)
      create_notice(turn)
      Rails.logger.warn(
        message: "chat_turn.stalled",
        chat_turn_id: turn.id,
        chat_session_id: turn.chat_session_id,
        side_effecting_tools_completed: turn.side_effecting_tools_completed?
      )
    end

    def create_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This turn stopped without a final assistant response. Completed tool activity remains in the transcript; anything after the last recorded activity is unknown. Review the preserved activity before retrying.",
        metadata: {
          "stalled_turn_notice" => true,
          "chat_turn_id" => turn.id,
          "user_message_id" => turn.user_message_id,
          "detected_at" => turn.detected_at.iso8601,
          "side_effecting_tools_completed" => turn.side_effecting_tools_completed?
        }
      )
    end
  end
end
