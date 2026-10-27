# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurn
    def self.call(...) = new(...).call

    def initialize(chat_turn:) = @chat_turn = chat_turn

    def call
      # @spec CHAT-API-027
      chat_turn.with_lock do
        return chat_turn unless chat_turn.state.in?(%w[pending streaming]) && chat_turn.last_activity_at <= ChatTurn::STALL_AFTER.ago
        return chat_turn if chat_turn.awaiting_confirmation? || chat_turn.chat_session.rate_limited?

        chat_turn.update!(state: "stalled", stalled_at: Time.current, metadata: chat_turn.metadata.merge("classification" => "missing_terminal_outcome"))
        notice = chat_turn.chat_session.messages.create!(role: "system", content: notice_content,
          metadata: { "stalled_turn_notice" => true, "chat_turn_id" => chat_turn.id, "initiating_message_id" => chat_turn.initiating_message_id })
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: chat_turn.id, chat_session_id: chat_turn.chat_session_id)
        notice
      end
    end

    private

    attr_reader :chat_turn

    def notice_content
      "This turn stopped before a final response was recorded. Any messages and tool results above were preserved, but the remaining work is unknown. Review completed tool activity before sending a new message; Paid will not replay tools automatically."
    end
  end
end
