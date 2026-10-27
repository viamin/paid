# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    DEFAULT_THRESHOLD = 10.minutes

    def self.call(...)
      new(...).call
    end

    def initialize(threshold: ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_THRESHOLD.to_i).to_i.seconds, now: Time.current)
      @threshold = threshold
      @now = now
    end

    # @spec CHAT-TURN-001, CHAT-TURN-002
    def call
      ChatTurn.stale_before(now - threshold).find_each.filter_map { |turn| stall(turn) }
    end

    private

    attr_reader :now, :threshold

    def stall(turn)
      turn.with_lock do
        return unless stale?(turn)
        return if turn.pending_confirmation?

        turn.update!(status: "stalled", classification: "no_durable_activity", stalled_at: now, activity_at: now,
          metadata: turn.metadata.merge("side_effecting_tool_completed" => turn.side_effecting_tool_completed?))
        notice(turn)
        turn
      end
    end

    def stale?(turn)
      turn.status.in?(ChatTurn::ACTIVE_STATUSES) && turn.activity_at < now - threshold
    end

    def notice(turn)
      turn.chat_session.messages.create!(role: "system", content: "This response stalled after its last saved activity. Earlier messages and tool results are preserved; the remaining response is unknown. Review any tool confirmations before retrying.", metadata: { "chat_turn_stalled_notice" => true, "chat_turn_id" => turn.id, "side_effecting_tool_completed" => turn.metadata["side_effecting_tool_completed"] })
    end
  end
end
