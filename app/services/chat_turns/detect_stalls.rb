# frozen_string_literal: true

module ChatTurns
  class DetectStalls
    DEFAULT_INACTIVITY_THRESHOLD = 10.minutes

    def self.call(now: Time.current, threshold: DEFAULT_INACTIVITY_THRESHOLD)
      new(now:, threshold:).call
    end

    def initialize(now:, threshold:)
      @now = now
      @threshold = threshold
    end

    def call
      ChatTurn.detectable(@now - @threshold).find_each.count { |turn| classify(turn) }
    end

    private

    def classify(turn)
      return false if turn.chat_session.rate_limited_until.present?
      return false if turn.chat_session.messages.pending_tool_confirmations.exists?
      return false unless turn.stall!

      turn.chat_session.messages.create!(
        role: "system",
        content: "This turn stopped without a final response. Earlier messages and completed tool results are preserved; no unfinished action was replayed. Review any tool cards, then explicitly resume this turn if it is safe to continue.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "detected_at" => @now.iso8601 }
      )
      Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
        user_message_id: turn.user_message_id, detected_at: @now.iso8601)
      true
    end
  end
end
