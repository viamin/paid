# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurns
    def self.call(...) = new(...).call

    def initialize(now: Time.current) = @now = now

    def call
      ChatTurn.stale_before(now - ChatTurn::STALL_THRESHOLD).find_each.filter_map { |turn| stall(turn) }
    end

    private

    attr_reader :now

    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
    def stall(turn)
      turn.with_lock do
        turn.reload
        return unless turn.state.in?(ChatTurn::ACTIVE_STATES)
        return if turn.last_activity_at >= now - ChatTurn::STALL_THRESHOLD
        return if turn.chat_session.messages.pending_tool_confirmations.exists?

        turn.stall!
        side_effects_completed = turn.chat_session.messages.where(role: "tool").where.not(tool_call_id: nil).exists?
        notice = turn.chat_session.messages.create!(role: "system", content: notice_content,
          metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "user_message_id" => turn.user_message_id,
                      "detected_at" => turn.detected_at.iso8601, "side_effecting_tools_completed" => side_effects_completed })
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
          user_message_id: turn.user_message_id, side_effecting_tools_completed: side_effects_completed)
        notice
      end
    end

    def notice_content
      "This request stopped without a saved final response. Any messages and tool results above were preserved, but the remaining work is unknown. Review the transcript before retrying: completed tool calls are not replayed automatically."
    end
  end
end
