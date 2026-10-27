# frozen_string_literal: true

module ChatTurns
  class RequestRecovery
    class ConflictError < ArgumentError; end

    # @spec CHAT-TURN-RECOVERY-004
    def self.call(turn:, actor:)
      turn.with_lock do
        unless turn.status == "stalled"
          ChatTurns::Track.record_event(turn, "recovery_duplicate", actor_id: actor.id, status: turn.status)
          raise ConflictError, "This chat turn is already being recovered or has reached a terminal state"
        end

        turn.update!(status: "streaming", recovery_attempts: turn.recovery_attempts + 1, last_activity_at: Time.current)
        ChatTurns::Track.record_event(turn, "recovery_requested", actor_id: actor.id, recovery_attempt: turn.recovery_attempts)
      end
      turn
    end
  end
end
