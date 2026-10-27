# frozen_string_literal: true

module ChatTurns
  # Mechanical watchdog for turns whose persisted transcript stopped advancing.
  # It deliberately does not retry: a stalled transcript is ambiguous until a
  # user explicitly chooses a recovery path.
  class DetectStalled
    DEFAULT_THRESHOLD = 10.minutes

    def self.call(...)
      new(...).call
    end

    def initialize(threshold: DEFAULT_THRESHOLD, now: Time.current)
      @threshold = threshold
      @now = now
    end

    def call
      ChatTurn.stale_before(@now - @threshold).find_each.count { |turn| stall(turn) }
    end

    private

    def stall(turn)
      turn.with_lock do
        return false unless stale?(turn)
        return false if protected?(turn)

        turn.complete!(status: "stalled", classification: "no_durable_activity")
        persist_notice(turn)
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
          user_message_id: turn.user_message_id, classification: turn.classification)
        true
      end
    end

    def stale?(turn)
      refresh_activity_from_transcript(turn)
      turn.status.in?(ChatTurn::ACTIVE_STATUSES) && turn.last_activity_at < (@now - @threshold)
    end

    def refresh_activity_from_transcript(turn)
      activity = turn.chat_session.messages.where("id > ?", turn.user_message_id).maximum(:created_at)
      return unless activity && activity > turn.last_activity_at

      turn.update_columns(last_activity_at: activity, updated_at: @now)
    end

    def protected?(turn)
      turn.chat_session.rate_limited? || turn.chat_session.messages.pending_tool_confirmations.exists?
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This turn stopped before a final response was saved. Any completed tool activity remains above; do not assume unfinished work ran. Review any pending confirmations, then send a new message to resume safely.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "classification" => turn.classification }
      )
    end
  end
end
