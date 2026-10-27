# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    def self.call(...)
      new(...).call
    end

    def initialize(now: Time.current)
      @now = now
    end

    def call
      ChatTurn.stale_streaming(now - ChatTurn.stall_threshold).find_each { |turn| classify(turn) }
    end

    private

    attr_reader :now

    # @spec CHAT-API-026
    def classify(turn)
      turn.with_lock do
        turn.reload
        return unless turn.status == "streaming" && turn.last_activity_at < now - ChatTurn.stall_threshold
        return if turn.chat_session.rate_limited? || turn.messages.pending_tool_confirmations.exists? || turn.operation_lease_active?(now)

        turn.update!(status: "stalled", stalled_at: now)
        turn.record_event!("stalled", detected_at: now.iso8601, side_effecting_tools_completed: turn.side_effecting_tools_completed?)
        persist_notice(turn)
      end
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        chat_turn: turn,
        role: "system",
        content: "This turn stopped making progress and needs attention. Completed tool activity is preserved; no assistant answer was recorded. Resume only if you want to continue from the saved checkpoint.",
        metadata: {
          "stalled_turn_notice" => true,
          "chat_turn_id" => turn.id,
          "side_effecting_tools_completed" => turn.side_effecting_tools_completed?
        }
      )
    end
  end
end
