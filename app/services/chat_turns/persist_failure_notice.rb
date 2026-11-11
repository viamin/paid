# frozen_string_literal: true

module ChatTurns
  # @spec CHAT-TURN-RECOVERY-008
  class PersistFailureNotice
    CONTENT = "The assistant could not finish this response. Any tool actions shown above may have completed. Please send a new message to continue."

    def self.call(chat_turn:)
      message = chat_turn.chat_session.messages.create!(
        role: "system",
        content: CONTENT,
        metadata: { "chat_turn_failure_notice" => true, "chat_turn_id" => chat_turn.id }
      )
      ActionCable.server.broadcast("chat_session:#{chat_turn.chat_session_id}", {
        type: "message_created",
        message_id: message.id,
        role: message.role,
        html: ApplicationController.render(partial: "chat_messages/message", locals: { message: message })
      })
      message
    rescue StandardError => e
      Rails.logger.error(message: "chat_turns.failure_notice_failed", chat_turn_id: chat_turn.id,
        error_class: e.class.name, error: e.message)
      nil
    end
  end
end
