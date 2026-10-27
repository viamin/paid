# frozen_string_literal: true

module ChatSessions
  module Turns
    class DetectStalled
      # @spec CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-004 CHAT-TURN-RECOVERY-012
      def self.call(turn:, now: Time.current)
        new(turn:, now:).call
      end

      def initialize(turn:, now:)
        @turn = turn
        @now = now
      end

      def call
        turn.with_lock do
          return unless stale?
          return abandon if awaiting_confirmation?
          return if protected_from_stall?
          return unless turn.mark_stalled!(classification)

          record("stall_detected", outcome: classification)
          StallNotice.call(turn: turn)
        end
      end

      private

      attr_reader :turn, :now

      def stale?
        turn.status.in?(ChatTurn::OPEN_STATUSES) && turn.last_activity_at <= now - timeout
      end

      def timeout
        turn.chat_session.account.tenant_setting&.chat_stall_timeout_seconds || 300
      end

      def awaiting_confirmation?
        turn.chat_session.messages.pending_tool_confirmations.exists?
      end

      def protected_from_stall?
        turn.chat_session.rate_limited_until.present? || token_limit_notice? || long_running_tool?
      end

      def token_limit_notice?
        turn.chat_session.messages.where(role: "system").any?(&:token_limit_error?)
      end

      def long_running_tool?
        tool = turn.chat_session.messages.where(role: "assistant").where.not(tool_name: nil).order(id: :desc).first
        tool && Tools::Registry.long_running?(tool.tool_name) && !tool.resolved_tool_confirmation?
      end

      def abandon
        return if turn.last_activity_at > now - abandonment_timeout

        turn.abandon!
        record("turn_abandoned", outcome: "awaiting_confirmation")
      end

      def abandonment_timeout
        timeout * 12
      end

      def classification
        "unknown"
      end

      def record(event_type, outcome:)
        ChatTurnEvent.create!(chat_turn: turn, chat_session: turn.chat_session, event_type:, outcome:,
          side_effecting_tools_completed: turn.side_effecting_tools_completed?, metadata: { "classification" => turn.failure_classification })
      end
    end
  end
end
