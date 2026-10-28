# frozen_string_literal: true

class ChatSessions::ProcessMessageJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound do |job, error|
    chat_session_id = job.arguments.first&.dig(:chat_session_id)
    stream_message_id = job.arguments.first&.dig(:stream_message_id)
    job.send(:broadcast_error, chat_session_id, stream_message_id, "Session no longer exists") if chat_session_id
  end

  def perform(chat_session_id:, content:, stream_message_id:, actor_id: nil, chat_turn_id: nil, recovery_attempt_id: nil)
    # @spec CHAT-API-002, CHAT-API-022
    chat_session = ChatSession.find(chat_session_id)
    actor = chat_session.account.users.find(actor_id || chat_session.created_by_id)
    stream_name = "chat_session:#{chat_session.id}"
    chat_turn = chat_session.chat_turns.find_by(id: chat_turn_id)
    recovery_attempt = start_recovery(recovery_attempt_id)

    chunk_sequence = 0

    assistant_message = ChatSessions::SendMessage.call(
      chat_session: chat_session,
      actor: actor,
      content: content,
      stream_message_id: stream_message_id,
      chat_turn: chat_turn,
      on_message_persisted: ->(message, stream_message_id: nil) {
        broadcast_persisted_message(stream_name, message, stream_message_id: stream_message_id)
      },
      on_chunk: ->(chunk) {
        chunk_sequence += 1
        ActionCable.server.broadcast(stream_name, {
          type: "message_chunk",
          message_id: stream_message_id,
          content: chunk,
          sequence: chunk_sequence
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
    complete_recovery(recovery_attempt, assistant_message)
  rescue ArgumentError => e
    broadcast_error(chat_session_id, stream_message_id, e.message)
  rescue NotImplementedError => e
    broadcast_error(chat_session_id, stream_message_id, e.message)
  rescue ChatSessions::LlmClientConfigurationError => e
    broadcast_error(chat_session_id, stream_message_id, e.message)
  rescue ChatSessions::TokenLimitExceededError => e # @spec CHAT-API-014
    broadcast_error(chat_session_id, stream_message_id, e.message,
      limit_type: e.limit_type, limit: e.limit, used: e.used)
  rescue AgentHarness::RateLimitError => e
    # @spec CHAT-API-017
    Rails.logger.warn(
      message: "chat_process_message_job.rate_limited",
      chat_session_id: chat_session_id,
      error_class: e.class.name,
      error: e.message
    )
    pause_message = ChatSessions::MarkRateLimited.call(chat_session: chat_session, error: e)
    broadcast_persisted_message(stream_name, pause_message)
    broadcast_error(chat_session_id, stream_message_id, ChatSessions::ErrorMessage.for(e))
  rescue AgentHarness::Error => e
    Rails.logger.error(
      message: "chat_process_message_job.provider_error",
      chat_session_id: chat_session_id,
      error_class: e.class.name,
      error: e.message
    )
    broadcast_error(chat_session_id, stream_message_id, ChatSessions::ErrorMessage.for(e))
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
  ensure
    fail_recovery(recovery_attempt_id) if recovery_attempt_id
  end

  private

  def start_recovery(recovery_attempt_id)
    return unless recovery_attempt_id

    ChatTurnRecoveryAttempt.find(recovery_attempt_id).tap do |attempt|
      attempt.update!(status: "running", started_at: Time.current)
    end
  end

  def complete_recovery(attempt, assistant_message)
    return unless attempt

    outcome = assistant_message ? "completed" : "awaiting_confirmation"
    attempt.update!(status: "completed", outcome:, completed_at: Time.current)
  end

  def fail_recovery(recovery_attempt_id)
    attempt = ChatTurnRecoveryAttempt.find_by(id: recovery_attempt_id, status: "running")
    attempt&.update!(status: "failed", outcome: "processing_error", completed_at: Time.current)
  end

  def broadcast_persisted_message(stream_name, message, stream_message_id: nil)
    # @spec CHAT-API-002
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

  def broadcast_error(chat_session_id, stream_message_id, error_message, **extra)
    stream_name = "chat_session:#{chat_session_id}"
    ActionCable.server.broadcast(stream_name, {
      type: "error",
      message_id: stream_message_id,
      message: error_message
    }.merge(extra.compact))
  end

  def tenant_account
    TenantContext.with_system_access do
      ChatSession.find_by(id: arguments.first&.dig(:chat_session_id))&.account
    end
  end
end
