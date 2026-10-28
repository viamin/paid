# frozen_string_literal: true

module ChatSessions
  # Marks abandoned server work visible without replaying the original prompt.
  # A pending confirmation and a known provider-rate-limit pause are durable
  # waits, not stalls, so neither is eligible for this detector.
  class DetectStalledTurns
    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
    DEFAULT_THRESHOLD = 10.minutes

    def self.call(...)
      new(...).call
    end

    def initialize(threshold: ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_THRESHOLD.to_i).to_i.seconds, now: Time.current)
      @threshold = threshold
      @now = now
    end

    def call
      ChatTurn.stale_before(now - threshold).find_each.count { |turn| stall(turn) }
    end

    private

    attr_reader :threshold, :now

    def stall(turn)
      turn.with_lock do
        turn.reload
        return false unless turn.status.in?(ChatTurn::ACTIVE_STATUSES)
        return false if turn.last_activity_at > now - threshold
        return false if turn.chat_session.rate_limited?
        return false if turn.chat_session.messages.pending_tool_confirmations.exists?

        turn.stall!
        persist_notice(turn)
        log_stall(turn)
        true
      end
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This response stopped before a final answer was saved. Earlier messages and tool results are preserved. Review any completed tool actions before retrying; no action was replayed automatically.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "classification" => turn.classification }
      )
    end

    def log_stall(turn)
      Rails.logger.warn(
        message: "chat_turn.stalled",
        chat_turn_id: turn.id,
        chat_session_id: turn.chat_session_id,
        classification: turn.classification,
        side_effecting_tools_completed: turn.chat_session.messages.where(role: "tool").exists?
      )
    end
  end
end
