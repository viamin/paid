# frozen_string_literal: true

module ChatTurns
  class DetectStalls # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
    DEFAULT_THRESHOLD = 10.minutes

    def self.call(now: Time.current, threshold: configured_threshold)
      new(now:, threshold:).call
    end

    def self.configured_threshold
      ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_THRESHOLD.to_i).to_i.seconds
    end

    def initialize(now:, threshold:)
      @now = now
      @threshold = threshold
    end

    def call
      ChatTurn.unfinished.where(last_activity_at: ...(@now - @threshold)).find_each do |turn|
        classify(turn)
      end
    end

    private

    def classify(turn)
      turn.with_lock do
        return unless stale?(turn)
        return if turn.awaiting_confirmation? || turn.chat_session.rate_limited?

        turn.stall!
        create_notice(turn)
      end
    end

    def stale?(turn)
      turn.status.in?(%w[pending streaming]) && turn.last_activity_at < (@now - @threshold)
    end

    def create_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This chat turn appears to have stopped before a final response was saved. " \
          "Any completed tool activity is preserved above; do not assume unfinished actions ran. " \
          "Review any tool confirmations, then send a new message to continue.",
        metadata: {
          "chat_turn_stalled_notice" => true,
          "chat_turn_id" => turn.id,
          "checkpoint_message_id" => turn.checkpoint_message_id,
          "classification" => "inactivity",
          "detected_at" => turn.stalled_at.iso8601
        }
      )
    end
  end
end
