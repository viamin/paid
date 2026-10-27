# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurn
    def self.call(...)
      new(...).call
    end

    def initialize(chat_turn:, now: Time.current)
      @chat_turn = chat_turn
      @now = now
    end

    def call
      chat_turn.with_lock do
        return false unless stale?

        chat_turn.update!(status: "stalled", detected_stalled_at: now, failure_classification: "no_durable_activity")
        persist_notice
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: chat_turn.id, chat_session_id: chat_turn.chat_session_id,
          last_activity_at: chat_turn.last_activity_at, side_effecting_tools_completed: false)
        true
      end
    end

    private

    attr_reader :chat_turn, :now

    def stale?
      chat_turn.status.in?(%w[pending streaming]) && chat_turn.last_activity_at < now - ChatTurn::STALL_THRESHOLD && !chat_turn.pending_confirmation?
    end

    def persist_notice
      chat_turn.chat_session.messages.create!(
        role: "system",
        content: "This response stopped before the server recorded a final outcome. Any completed messages and tool results above were preserved; no completion was recorded. Review the transcript before retrying, especially any tool confirmations.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => chat_turn.id, "failure_classification" => chat_turn.failure_classification }
      )
    end
  end
end
