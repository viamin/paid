# frozen_string_literal: true

class ChatSessions::ResumeRateLimitedJob < ApplicationJob
  queue_as :maintenance

  discard_on ActiveRecord::RecordNotFound

  # @spec CHAT-API-017
  def perform(chat_session_id:)
    # Runs from a background sweep with no request-scoped tenant context;
    # bypass RLS to load the session, then scope the actual resume to its
    # account (mirrors ChatSessions::IdleReaperJob).
    chat_session = TenantContext.with_system_access { ChatSession.find(chat_session_id) }
    return if chat_session.rate_limited_until.blank?
    return if chat_session.rate_limited_until > Time.current

    TenantContext.with(chat_session.account) { resume(chat_session) }
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    Rails.logger.error(
      message: "chat_resume_rate_limited_job.failed",
      chat_session_id: chat_session_id,
      error_class: e.class.name,
      error: e.message
    )
  end

  private

  def resume(chat_session)
    stream_message_id = SecureRandom.uuid
    stream_name = "chat_session:#{chat_session.id}"

    ActionCable.server.broadcast(stream_name, { type: "message_start", message_id: stream_message_id })

    assistant_message = ChatSessions::ResumeRateLimited.call(
      chat_session: chat_session,
      stream_message_id: stream_message_id,
      on_message_persisted: ->(message, stream_message_id: nil) {
        broadcast_persisted_message(stream_name, message, stream_message_id: stream_message_id)
      },
      on_chunk: ->(chunk) {
        ActionCable.server.broadcast(stream_name, { type: "message_chunk", message_id: stream_message_id, content: chunk })
      }
    )

    ActionCable.server.broadcast(stream_name, {
      type: "message_complete",
      message_id: stream_message_id,
      tokens: { input: assistant_message&.tokens_input, output: assistant_message&.tokens_output }
    })

    Rails.logger.info(
      message: "chat_session.rate_limit_auto_resumed",
      chat_session_id: chat_session.id,
      resumed: assistant_message.present?
    )
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
end
