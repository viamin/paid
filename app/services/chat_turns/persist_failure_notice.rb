# frozen_string_literal: true

module ChatTurns
  # @spec CHAT-TURN-RECOVERY-008
  class PersistFailureNotice
    CONTENT = "The assistant could not finish this response. Any tool actions shown above may have completed."
    EMPTY_RESPONSE_CONTENT = "The assistant returned no usable response. You can retry this turn; completed tool actions will not be repeated."
    EMPTY_RESPONSE_EXHAUSTED_CONTENT = "The assistant returned no usable response. Recovery attempts are exhausted; send a new message to continue."

    def self.call(chat_turn:)
      message = latest_notice(chat_turn) || chat_turn.chat_session.messages.build(role: "system")
      message.assign_attributes(content: notice_content(chat_turn), metadata: notice_metadata(chat_turn))
      message.save!
      broadcast(chat_turn, message)
      message
    rescue StandardError => e
      Rails.logger.error(message: "chat_turns.failure_notice_failed", chat_turn_id: chat_turn.id,
        error_class: e.class.name, error: e.message)
      nil
    end

    def self.notice_content(chat_turn)
      return EMPTY_RESPONSE_EXHAUSTED_CONTENT if chat_turn.failure_classification == "empty_response" && chat_turn.recovery_exhausted?
      return EMPTY_RESPONSE_CONTENT if chat_turn.failure_classification == "empty_response"

      CONTENT
    end

    def self.retire_retry!(chat_turn:)
      message = latest_notice(chat_turn)
      return unless message&.metadata&.fetch("retry_available", false)

      message.update!(metadata: message.metadata.merge("retry_available" => false))
      broadcast(chat_turn, message)
      message
    end

    def self.notice_metadata(chat_turn)
      {
        "chat_turn_failure_notice" => true,
        "chat_turn_id" => chat_turn.id,
        "retry_available" => chat_turn.failure_classification == "empty_response" && !chat_turn.recovery_exhausted?
      }
    end

    def self.latest_notice(chat_turn)
      chat_turn.chat_session.messages
        .where("metadata @> ?", { chat_turn_failure_notice: true, chat_turn_id: chat_turn.id }.to_json)
        .order(id: :desc)
        .first
    end

    def self.broadcast(chat_turn, message)
      ActionCable.server.broadcast("chat_session:#{chat_turn.chat_session_id}", {
        type: "message_created",
        message_id: message.id,
        role: message.role,
        html: ApplicationController.render(partial: "chat_messages/message", locals: { message: message })
      })
    end
  end
end
