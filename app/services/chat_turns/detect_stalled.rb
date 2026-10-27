# frozen_string_literal: true

module ChatTurns
  # Classifies only durable inactivity. Pending confirmations and known
  # rate-limit pauses have their own visible/recoverable state and are never
  # relabelled as a stall.
  # @spec API-CONVERSATION-DELEGATION-008
  class DetectStalled
    DEFAULT_THRESHOLD = 10.minutes

    def initialize(now: Time.current, threshold: DEFAULT_THRESHOLD)
      @now = now
      @threshold = threshold
    end

    def self.call(...)
      new(...).call
    end

    def call
      ChatTurn.eligible_for_stall_detection(now - threshold).find_each.count do |turn|
        classify(turn)
      end
    end

    private

    attr_reader :now, :threshold

    def classify(turn)
      turn.with_lock do
        turn.reload
        return false unless stale?(turn)
        return false if protected?(turn)

        turn.stalled!
        persist_notice(turn)
        audit(turn)
        true
      end
    end

    def stale?(turn)
      turn.status.in?(%w[pending streaming]) && turn.last_activity_at <= now - threshold
    end

    def protected?(turn)
      turn.chat_session.rate_limited? || turn.chat_session.messages.pending_tool_confirmations.exists?
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This response stopped before the assistant produced a final answer. Completed tool activity remains in this transcript; any unfinished work is unknown. Review completed tools and confirmations, then explicitly retry or continue with a new message. No tool has been replayed.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "severity" => "warning" }
      )
    end

    def audit(turn)
      Rails.logger.warn(
        message: "chat_turn.stalled",
        chat_turn_id: turn.id,
        chat_session_id: turn.chat_session_id,
        detected_at: turn.detected_stalled_at,
        side_effecting_tools_completed: completed_write_tools?(turn)
      )
    end

    def completed_write_tools?(turn)
      turn.chat_session.messages.where(role: "assistant", tool_status: "approved").exists?
    end
  end
end
