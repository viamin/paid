# frozen_string_literal: true

module ChatTurns
  class DetectStalls
    DEFAULT_THRESHOLD = 10.minutes

    def self.call(...)
      new(...).call
    end

    def initialize(now: Time.current, threshold: DEFAULT_THRESHOLD)
      @now = now
      @threshold = threshold
    end

    def call
      ChatTurn.stale_before(@now - @threshold).find_each.filter_map { |turn| classify(turn) }
    end

    private

    def classify(turn)
      return if turn.pending_confirmation? || turn.expected_to_continue?

      turn.with_lock do
        turn.reload
        return unless turn.status.in?(ChatTurn::ACTIVE_STATUSES) && turn.last_activity_at < @now - @threshold
        return if turn.pending_confirmation? || turn.expected_to_continue?

        turn.update!(status: "stalled", detected_stalled_at: @now,
          metadata: turn.metadata.merge("stall_classification" => "missing_durable_activity"))
        persist_notice(turn)
        turn
      end
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This turn stopped without a final response. Completed tool activity is preserved, but the remaining response is unknown. Review any tool confirmations before retrying; send a new message only if it is safe to repeat the request.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "initiating_message_id" => turn.initiating_message_id }
      )
    end
  end
end
