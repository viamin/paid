# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    DEFAULT_TIMEOUT = 10.minutes

    def self.call(now: Time.current)
      new(now:).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      ChatTurn.stale_before(@now - timeout).find_each.count { |turn| classify(turn) }
    end

    private

    def timeout
      seconds = ENV.fetch("CHAT_TURN_STALL_TIMEOUT_SECONDS", DEFAULT_TIMEOUT.to_i).to_i
      seconds.positive? ? seconds.seconds : DEFAULT_TIMEOUT
    end

    def classify(turn)
      return false unless turn.stall!

      persist_notice(turn)
      Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
        user_message_id: turn.user_message_id, detected_at: turn.detected_at)
      true
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This chat turn stopped before a final response was saved. Any completed tool activity remains above; the remaining work is unknown. Review any pending confirmations before sending a new message so Paid does not repeat an action.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "user_message_id" => turn.user_message_id }
      )
    end
  end
end
