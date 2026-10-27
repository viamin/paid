# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurns
    def self.call(...) = new(...).call

    def initialize(now: Time.current, threshold: ChatTurn::STALL_THRESHOLD)
      @now = now
      @threshold = threshold
    end

    def call
      ChatTurn.stale_before(@now - @threshold).find_each.filter_map { |turn| classify(turn) }
    end

    private

    def classify(turn)
      turn.with_lock do
        return unless turn.status.in?(%w[pending streaming])
        return if turn.last_activity_at >= (@now - @threshold)
        return if turn.pending_confirmation?

        turn.update!(status: "stalled", detected_at: @now, failure_classification: "no_durable_activity")
        turn.events.create!(event_type: "stalled", metadata: { "detected_at" => @now.iso8601 })
        notice = turn.chat_session.messages.create!(
          role: "system",
          content: "This chat turn stopped without a final response. Completed activity is preserved; the remaining work is unknown. Review the visible tool activity before retrying, because retrying may repeat work.",
          metadata: { "chat_turn_stalled_notice" => true, "chat_turn_id" => turn.id }
        )
        turn.events.create!(event_type: "notice_created", metadata: { "chat_message_id" => notice.id })
        turn
      end
    end
  end
end
