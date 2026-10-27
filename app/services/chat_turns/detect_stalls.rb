# frozen_string_literal: true

module ChatTurns
  # @spec CHAT-TURN-LIFECYCLE-003 @spec CHAT-TURN-LIFECYCLE-004 @spec CHAT-TURN-LIFECYCLE-011
  class DetectStalls
    DEFAULT_THRESHOLD = 15.minutes

    def self.call(now: Time.current)
      new(now:).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      ChatTurn.running.includes(:chat_session, :account).find_each.filter_map { |turn| detect(turn) }
    end

    private

    attr_reader :now

    def detect(turn)
      return unless stale?(turn)
      return if pending_confirmation?(turn)

      turn.with_lock do
        next unless %w[pending streaming].include?(turn.status) && stale?(turn)

        classification = classify(turn)
        turn.mark_stalled!(classification:, detected_at: now)
        record_detection(turn, classification)
        StallNotice.call(chat_turn: turn)
        request_automatic_recovery(turn) if automatically_recoverable?(turn)
        turn
      end
    end

    def stale?(turn)
      turn.last_activity_at <= now - threshold(turn)
    end

    def threshold(turn)
      seconds = turn.account.tenant_setting&.chat_turn_stall_threshold_seconds
      seconds.to_i.positive? ? seconds.to_i.seconds : DEFAULT_THRESHOLD
    end

    def pending_confirmation?(turn)
      turn.chat_messages.pending_tool_confirmations.exists?
    end

    def classify(turn)
      return "model_stop" if turn.chat_messages.where(role: "assistant").where.not(content: nil).exists?

      "infrastructure_failure"
    end

    def record_detection(turn, classification)
      ChatTurnEvent.create!(chat_turn: turn, chat_session: turn.chat_session, account: turn.account,
        event_type: "stall_detected", classification:, side_effecting_tools_completed: turn.side_effecting_tools_completed,
        metadata: { detected_at: now.iso8601, checkpoint_message_id: turn.checkpoint_message_id })
    end

    def automatically_recoverable?(turn)
      turn.auto_recoverable_classification? && !turn.recovery_budget_exhausted? && ReplaySafety.automatic?(turn)
    end

    def request_automatic_recovery(turn)
      ChatTurns::RequestRecovery.call(chat_turn: turn, actor: turn.chat_session.created_by, confirmed: true)
    end
  end
end
