# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    STALL_AFTER = 15.minutes

    # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-004
    def self.call(...)
      new(...).call
    end

    def initialize(now: Time.current)
      @now = now
    end

    def call
      ChatTurn.stale_candidates(@now - STALL_AFTER).find_each { |turn| detect(turn) }
    end

    private

    def detect(turn)
      turn.with_lock do
        return unless turn.status.in?(ChatTurn::ACTIVE_STATUSES) && turn.last_activity_at < @now - STALL_AFTER

        safe = turn.auto_recovery_safe?
        turn.transition!("stalled", now: @now, detected_at: @now,
          failure_classification: "infrastructure_interruption",
          metadata: turn.metadata.merge("auto_recovery_eligible" => safe, "tool_activity_observed" => turn.tool_activity?))
        notice(turn)
        schedule_recovery(turn) if safe
      end
    end

    def notice(turn)
      return if turn.chat_session.messages.system.where("metadata ->> 'chat_turn_id' = ?", turn.id.to_s).exists?

      tool_state = turn.tool_activity? ? "Tool activity was recorded; its final outcome is unknown." : "No tool calls were durably recorded."
      turn.chat_session.messages.create!(role: "system", content: "This chat turn stalled. #{tool_state} You can safely retry only after reviewing this turn.",
        metadata: { "chat_turn_stalled" => true, "chat_turn_id" => turn.id, "user_message_id" => turn.user_message_id })
    end

    def schedule_recovery(turn)
      turn.update!(recovery_attempts: 1, recovery_started_at: @now, recovery_token: SecureRandom.uuid)
      ChatSessions::RecoverStalledTurnJob.perform_later(chat_turn_id: turn.id)
    end
  end
end
