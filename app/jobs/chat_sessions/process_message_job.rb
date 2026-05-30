# frozen_string_literal: true

class ChatSessions::ProcessMessageJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound do |job, error|
    chat_session_id = job.arguments.first&.dig(:chat_session_id)
    stream_message_id = job.arguments.first&.dig(:stream_message_id)
    job.send(:broadcast_error, chat_session_id, stream_message_id, "Session no longer exists") if chat_session_id
  end

  def perform(chat_session_id:, content:, stream_message_id:)
    chat_session = ChatSession.find(chat_session_id)
    stream_name = "chat_session:#{chat_session.id}"

    llm_client = ChatSessions::BuildLlmClient.call(chat_session: chat_session)

    assistant_message = ChatSessions::SendMessage.call(
      chat_session: chat_session,
      content: content,
      stream_message_id: stream_message_id,
      llm_client: llm_client,
      on_message_persisted: ->(message, stream_message_id: nil) {
        broadcast_persisted_message(stream_name, message, stream_message_id: stream_message_id)
      },
      on_chunk: ->(chunk) {
        ActionCable.server.broadcast(stream_name, {
          type: "message_chunk",
          message_id: stream_message_id,
          content: chunk
        })
      }
    )

    ActionCable.server.broadcast(stream_name, {
      type: "message_complete",
      message_id: stream_message_id,
      tokens: {
        input: assistant_message.tokens_input,
        output: assistant_message.tokens_output
      }
    })
  rescue ArgumentError => e
    broadcast_error(chat_session_id, stream_message_id, e.message)
  rescue NotImplementedError => e
    broadcast_error(chat_session_id, stream_message_id, e.message)
  rescue ChatSessions::LlmClientConfigurationError => e
    broadcast_error(chat_session_id, stream_message_id, e.message)
  rescue ChatSessions::TokenLimitExceededError => e
    broadcast_error(chat_session_id, stream_message_id, e.message)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    Rails.logger.error(
      message: "chat_process_message_job.failed",
      chat_session_id: chat_session_id,
      error_class: e.class.name,
      error: e.message
    )
    broadcast_error(chat_session_id, stream_message_id, "An unexpected error occurred")
  end

  private

  def broadcast_persisted_message(stream_name, message, stream_message_id: nil)
    ActionCable.server.broadcast(stream_name, {
      type: "message_created",
      message_id: message.id,
      role: message.role,
      stream_message_id: stream_message_id,
      html: ApplicationController.render(
        partial: "chat_messages/message",
        locals: { message: message }
      )
    })
  end

  def broadcast_error(chat_session_id, stream_message_id, error_message)
    stream_name = "chat_session:#{chat_session_id}"
    ActionCable.server.broadcast(stream_name, {
      type: "error",
      message_id: stream_message_id,
      message: error_message
    })
  end

  def tenant_account
    TenantContext.with_system_access do
      ChatSession.find_by(id: arguments.first&.dig(:chat_session_id))&.account
    end
  end
end
