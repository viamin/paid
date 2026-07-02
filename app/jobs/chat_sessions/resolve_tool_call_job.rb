# frozen_string_literal: true

class ChatSessions::ResolveToolCallJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound do |job, error|
    chat_session_id = job.arguments.first&.dig(:chat_session_id)
    stream_message_id = job.arguments.first&.dig(:stream_message_id)
    job.send(:broadcast_error, chat_session_id, stream_message_id, "Session no longer exists") if chat_session_id
  end

  def perform(chat_session_id:, message_id:, decision:, stream_message_id:)
    chat_session = ChatSession.find(chat_session_id)
    tool_call_message = chat_session.messages.find(message_id)
    stream_name = "chat_session:#{chat_session.id}"

    ActionCable.server.broadcast(stream_name, {
      type: "message_start",
      message_id: stream_message_id
    })

    assistant_message = ChatSessions::ResolveToolCall.call(
      chat_session: chat_session,
      tool_call_message: tool_call_message,
      decision: decision,
      stream_message_id: stream_message_id,
      on_tool_call_resolved: ->(message) {
        broadcast_tool_call_resolved(stream_name, message)
      },
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
        input: assistant_message&.tokens_input,
        output: assistant_message&.tokens_output
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
  rescue AgentHarness::RateLimitError => e
    Rails.logger.warn(
      message: "chat_resolve_tool_call_job.rate_limited",
      chat_session_id: chat_session_id,
      error_class: e.class.name,
      error: e.message
    )
    broadcast_error(chat_session_id, stream_message_id, ChatSessions::ErrorMessage.for(e))
  rescue AgentHarness::Error => e
    Rails.logger.error(
      message: "chat_resolve_tool_call_job.provider_error",
      chat_session_id: chat_session_id,
      error_class: e.class.name,
      error: e.message
    )
    broadcast_error(chat_session_id, stream_message_id, ChatSessions::ErrorMessage.for(e))
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    Rails.logger.error(
      message: "chat_resolve_tool_call_job.failed",
      chat_session_id: chat_session_id,
      error_class: e.class.name,
      error: e.message
    )
    broadcast_error(chat_session_id, stream_message_id, "An unexpected error occurred")
  end

  private

  def broadcast_tool_call_resolved(stream_name, message)
    ActionCable.server.broadcast(stream_name, {
      type: "message_tool_resolved",
      message_id: message.id,
      role: message.role,
      tool_status: message.tool_status,
      tool_name: message.tool_name,
      tool_call_id: message.tool_call_id,
      tool_arguments: message.tool_arguments,
      html: ApplicationController.render(
        partial: "chat_messages/message",
        locals: { message: message }
      )
    })
  end

  def broadcast_persisted_message(stream_name, message, stream_message_id: nil)
    event_type = if message.role == "tool"
      "message_tool_result"
    elsif message.role == "assistant" && message.tool_name.present? && message.content.nil?
      message.pending_confirmation? ? "message_tool_confirmation" : "message_tool_call"
    else
      "message_created"
    end

    ActionCable.server.broadcast(stream_name, {
      type: event_type,
      message_id: message.id,
      role: message.role,
      tool_name: message.tool_name,
      tool_call_id: message.tool_call_id,
      tool_arguments: message.tool_arguments,
      tool_result: message.tool_result,
      fallback_notice: message.fallback_notice?,
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
end
