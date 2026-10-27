# frozen_string_literal: true

module ChatTurns
  # Classifies inactive in-flight turns without inferring a successful answer.
  # Recovery is deliberately not attempted here: the persisted tool transcript
  # cannot prove that replaying a call is idempotent.
  class DetectStalled
    DEFAULT_THRESHOLD = 10.minutes

    def self.call(now: Time.current)
      new(now:).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      ChatTurn.stale_candidates(@now - threshold).find_each { |turn| stall(turn) }
    end

    private

    def threshold
      seconds = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_THRESHOLD.to_i).to_i
      seconds.positive? ? seconds.seconds : DEFAULT_THRESHOLD
    end

    def stall(turn)
      return unless turn.status.in?(ChatTurn::ACTIVE_STATUSES)
      return unless turn.last_activity_at < (@now - threshold)
      return unless turn.stall!

      persist_notice(turn)
      Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id,
        chat_session_id: turn.chat_session_id, detected_at: @now)
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This response stopped before a final answer was saved. Completed tool results remain above; any later work is unknown. " \
          "No tool call will be repeated automatically. Review the saved results, then send a new message to continue safely.",
        metadata: { "chat_turn_stalled_notice" => true, "chat_turn_id" => turn.id }
      )
    end
  end
end
