# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurns
    def initialize(now: Time.current)
      @now = now
    end

    def self.call(...)
      new(...).call
    end

    def call
      ChatTurn.stale_at(now).find_each { |turn| stall(turn) }
    end

    private

    attr_reader :now

    # @spec CHAT-API-026
    def stall(turn)
      turn.with_lock do
        return unless turn.status.in?(%w[pending streaming]) && turn.last_activity_at < now - ChatTurn::STALL_TIMEOUT
        return if turn.chat_session.messages.pending_tool_confirmations.exists?

        turn.update!(status: "stalled", stalled_at: now, failure_classification: "unknown")
        completed_tool_message_ids = turn.chat_session.messages.where(role: "tool").where("id > ?", turn.user_message_id).pluck(:id)
        turn.chat_session.messages.create!(
          role: "system",
          content: "This response stopped before a final answer was saved. Earlier tool activity is preserved; review it before continuing because the remaining work is unknown.",
          metadata: {
            "stalled_turn_notice" => true,
            "chat_turn_id" => turn.id,
            "failure_classification" => "unknown",
            "completed_tool_message_ids" => completed_tool_message_ids
          }
        )
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
          failure_classification: "unknown")
      end
    end
  end
end
