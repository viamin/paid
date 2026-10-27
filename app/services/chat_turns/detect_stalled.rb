# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    DEFAULT_INACTIVITY_THRESHOLD = 10.minutes

    def self.call(now: Time.current)
      new(now:).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      ChatTurn.inactive_before(@now - inactivity_threshold).find_each.count { |turn| stall(turn) }
    end

    private

    def inactivity_threshold
      configured = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_INACTIVITY_THRESHOLD.to_i).to_i
      configured.positive? ? configured.seconds : DEFAULT_INACTIVITY_THRESHOLD
    end

    def stall(turn)
      turn.with_lock do
        turn.reload
        return false unless stale?(turn)
        return false if intentional_wait?(turn)

        turn.stall!(detected_at: @now)
        persist_notice(turn)
        true
      end
    end

    def stale?(turn)
      turn.status.in?(%w[pending streaming]) && turn.last_activity_at < @now - inactivity_threshold
    end

    def intentional_wait?(turn)
      turn.chat_session.rate_limited? || turn.chat_session.messages.pending_tool_confirmations.exists?
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: notice_content(turn),
        metadata: {
          "chat_turn_stalled" => true,
          "chat_turn_id" => turn.id,
          "side_effecting_tools_completed" => turn.side_effecting_tools_completed
        }
      )
    end

    def notice_content(turn)
      completed = turn.side_effecting_tools_completed ? "One or more side-effecting tools may have completed." : "No side-effecting tool completion was recorded."
      "This response stopped before a durable conclusion. #{completed} The remaining model response is unknown. Review the transcript before retrying."
    end
  end
end
