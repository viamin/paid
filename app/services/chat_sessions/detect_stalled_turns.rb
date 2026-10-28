# frozen_string_literal: true

module ChatSessions
  # Classifies turns which lost their worker without a terminal outcome. It
  # deliberately excludes confirmation pauses: those have a durable user
  # action, rather than an unknown execution state.
  class DetectStalledTurns
    DEFAULT_INACTIVITY_THRESHOLD = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", 10.minutes.to_i).to_i.seconds

    def initialize(now: Time.current, inactivity_threshold: DEFAULT_INACTIVITY_THRESHOLD)
      @now = now
      @inactivity_threshold = inactivity_threshold
    end

    def self.call(...)
      new(...).call
    end

    def call
      ChatTurn.stale_before(@now - @inactivity_threshold).find_each.count do |turn|
        classify(turn)
      end
    end

    private

    def classify(turn)
      turn.with_lock do
        turn.reload
        return false unless turn.lifecycle.in?(ChatTurn::ACTIVE_LIFECYCLES)
        return false if turn.last_activity_at > (@now - @inactivity_threshold)

        turn.stall!(classification: "inactivity_timeout")
        create_notice(turn)
        log_stall(turn)
        true
      end
    end

    def create_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This chat turn stopped without a final response. Completed tool activity is preserved above; no additional tool calls were run after activity stopped. Review any completed tool results or pending confirmations before retrying.",
        metadata: {
          "stalled_turn_notice" => true,
          "chat_turn_id" => turn.id,
          "classification" => turn.classification,
          "detected_at" => turn.detected_at.iso8601
        }
      )
    end

    def log_stall(turn)
      Rails.logger.warn(
        message: "chat_turn.stalled",
        chat_turn_id: turn.id,
        chat_session_id: turn.chat_session_id,
        classification: turn.classification,
        detected_at: turn.detected_at
      )
    end
  end
end
