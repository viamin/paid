# frozen_string_literal: true

module ChatSessions
  # Marks only turns with no durable progress as stalled. A confirmation pause
  # and an explicit provider failure are terminal states, never stalls.
  class DetectStalledTurns
    DEFAULT_TIMEOUT = 30.minutes

    def self.call(now: Time.current, timeout: timeout_from_environment)
      new(now:, timeout:).call
    end

    def self.timeout_from_environment
      Integer(ENV.fetch("CHAT_TURN_STALL_TIMEOUT_SECONDS", DEFAULT_TIMEOUT.to_i)).seconds
    rescue ArgumentError
      DEFAULT_TIMEOUT
    end

    def initialize(now:, timeout:)
      @now = now
      @timeout = timeout
    end

    def call
      ChatTurn.stale_before(@now - @timeout).find_each.count { |turn| classify(turn) }
    end

    private

    def classify(turn)
      turn.with_lock do
        return false unless turn.state.in?(ChatTurn::ACTIVE_STATES)
        return false unless turn.last_activity_at <= (@now - @timeout)

        return complete_confirmation(turn) if turn.pending_confirmation?

        mark_stalled(turn)
      end
    end

    def complete_confirmation(turn)
      turn.complete!(reason: "awaiting_confirmation")
      false
    end

    def mark_stalled(turn)
      turn.update!(state: "stalled", detected_stalled_at: @now, last_activity_at: @now,
        failure_classification: "missing_durable_activity")
      create_notice(turn)
      Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id,
        chat_session_id: turn.chat_session_id, user_message_id: turn.user_message_id,
        detected_at: @now.iso8601, failure_classification: turn.failure_classification)
      true
    end

    def create_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This response stopped before Paid recorded a final assistant answer. Any tool activity already shown above is preserved, but the remaining work is unknown. Review completed tool results before sending a new message so Paid does not repeat a side effect.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id,
                    "user_message_id" => turn.user_message_id, "detected_at" => @now.iso8601 }
      )
    end
  end
end
