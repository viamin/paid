# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    DEFAULT_THRESHOLD = 10.minutes

    def self.call(...)
      new(...).call
    end

    def initialize(now: Time.current, threshold: DEFAULT_THRESHOLD)
      @now = now
      @threshold = threshold
    end

    def call
      ChatTurn.inactive_before(@now - @threshold).find_each { |turn| detect(turn) }
    end

    private

    def detect(turn)
      turn.with_lock do
        return unless eligible?(turn)

        turn.stall!
        turn.chat_session.messages.create!(role: "system", content: notice_content(turn), metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id })
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id)
      end
    end

    def eligible?(turn)
      turn.reload.state.in?(%w[pending streaming]) && turn.last_activity_at < (@now - @threshold) &&
        !turn.chat_session.messages.pending_tool_confirmations.exists? && turn.chat_session.rate_limited_until.blank?
    end

    def notice_content(turn)
      "This chat turn stopped before Paid recorded a final assistant response. Any messages and tool results above were preserved, but the remaining work is unknown. Review any tool confirmations before sending a new request; Paid did not replay tools automatically."
    end
  end
end
