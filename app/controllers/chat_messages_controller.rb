# frozen_string_literal: true

class ChatMessagesController < ApplicationController
  include ActionController::Live

  skip_after_action :verify_authorized, only: :index
  before_action :set_chat_session
  before_action :reject_archived_chat_session, only: %i[create resolve]

  rate_limit to: ChatMessages::RateLimit::MAX_REQUESTS, within: ChatMessages::RateLimit::PERIOD,
    by: -> { ChatMessages::RateLimit.identifier(user_id: current_user&.id, chat_session_id: params[:chat_session_id]) },
    with: -> { render json: { error: "Rate limit exceeded" }, status: :too_many_requests },
    only: %i[create resolve]

  def index
    messages = policy_scope(ChatMessage)
      .where(chat_session: @chat_session)

    messages = messages.where(role: params[:role]) if params[:role].present?
    messages = messages.where("chat_messages.id < ?", params[:before]) if params[:before].present?

    messages = messages.order(created_at: :desc).limit(50)

    render json: messages.reverse.map { |m| message_json(m) }
  end

  def create
    authorize ChatMessage.new(chat_session: @chat_session), policy_class: ChatMessagePolicy

    if params[:content].blank?
      render json: { error: "content is required" }, status: :unprocessable_content
      return
    end

    if params[:content].to_s.length > ChatSessions::SendMessage::MAX_CONTENT_LENGTH
      render json: { error: "content exceeds maximum length" }, status: :unprocessable_content
      return
    end

    if sse_requested?
      # @spec CHAT-API-002
      stream_sse_response
    else
      # @spec CHAT-API-002
      json_response
    end
  end

  def resolve
    tool_call_message = @chat_session.messages.find(params[:id])
    authorize tool_call_message, :resolve?, policy_class: ChatMessagePolicy

    decision = params[:decision].to_s
    unless %w[approve deny].include?(decision)
      render json: { error: "decision must be approve or deny" }, status: :unprocessable_content
      return
    end

    if sse_requested?
      # @spec CHAT-API-004
      stream_resolve_response(tool_call_message, decision)
    else
      # @spec CHAT-API-004
      json_resolve_response(tool_call_message, decision)
    end
  end

  private

  def set_chat_session
    @chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
  end

  def reject_archived_chat_session
    return unless @chat_session&.archived?

    render json: { error: "Chat session is archived." }, status: :unprocessable_entity
  end

  def sse_requested?
    request.headers["Accept"]&.include?("text/event-stream")
  end

  def stream_sse_response
    with_chat_session_tenant_context do
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      message_id = SecureRandom.uuid

      write_sse_event("message_start", { message_id: message_id, model: @chat_session.model })

      assistant_message = ChatSessions::SendMessage.call(
        chat_session: @chat_session,
        content: params[:content],
        on_chunk: ->(chunk) { write_sse_event("message_chunk", { message_id: message_id, content: chunk }) },
        on_message_persisted: ->(message, stream_message_id: nil) { write_sse_tool_event(message, stream_message_id: stream_message_id) }
      )

      write_sse_event("message_complete", {
        message_id: message_id,
        tokens: {
          input: assistant_message&.tokens_input,
          output: assistant_message&.tokens_output
        }
      })
    end
  rescue IOError
    # Client disconnected — nothing to send
  rescue NotImplementedError => e
    write_sse_event("error", { message: e.message }) rescue IOError
  rescue ChatSessions::LlmClientConfigurationError => e
    write_sse_event("error", { message: e.message }) rescue IOError
  rescue ArgumentError => e
    write_sse_event("error", { message: e.message }) rescue IOError
  rescue AgentHarness::RateLimitError => e
    write_sse_event("error", { message: ChatSessions::ErrorMessage.for(e) }) rescue IOError
  rescue AgentHarness::Error => e
    write_sse_event("error", { message: ChatSessions::ErrorMessage.for(e) }) rescue IOError
  rescue StandardError => e
    Rails.logger.error(message: "chat_messages.stream_failed", session_id: @chat_session.id, error: e.message)
    write_sse_event("error", { message: "An unexpected error occurred" }) rescue IOError
  ensure
    response.stream.close
  end

  def json_response
    assistant_message = with_chat_session_tenant_context do
      ChatSessions::SendMessage.call(
        chat_session: @chat_session,
        content: params[:content]
      )
    end

    render json: assistant_response_payload(assistant_message), status: :created
  rescue NotImplementedError => e
    render json: { error: e.message }, status: :service_unavailable
  rescue ChatSessions::LlmClientConfigurationError => e
    render json: { error: e.message }, status: :service_unavailable
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_content
  rescue AgentHarness::RateLimitError => e
    render json: { error: ChatSessions::ErrorMessage.for(e) }, status: :too_many_requests
  rescue AgentHarness::Error => e
    render json: { error: ChatSessions::ErrorMessage.for(e) }, status: :bad_gateway
  rescue StandardError => e
    Rails.logger.error(message: "chat_messages.send_failed", session_id: @chat_session.id, error: e.message)
    render json: { error: "An unexpected error occurred" }, status: :internal_server_error
  end

  def write_sse_event(event, data)
    response.stream.write("event: #{event}\ndata: #{data.to_json}\n\n")
  end

  def write_sse_tool_event(message, stream_message_id: nil)
    if message.fallback_notice?
      write_sse_event("message_created", message_json(message).merge(
        fallback_notice: true,
        stream_message_id: nil
      ))
      return
    end

    event_type = if message.role == "tool"
      "message_tool_result"
    elsif message.role == "assistant" && message.tool_name.present? && message.content.nil?
      message.pending_confirmation? ? "message_tool_confirmation" : "message_tool_call"
    end

    return unless event_type

    # Payload mirrors the Cable channel shape (see ProcessMessageJob#broadcast_persisted_message),
    # omitting `html` since SSE is an API channel and clients consume structured data directly.
    write_sse_event(event_type, {
      message_id: message.id,
      role: message.role,
      tool_name: message.tool_name,
      tool_call_id: message.tool_call_id,
      tool_arguments: message.tool_arguments,
      tool_result: message.tool_result,
      tool_status: message.tool_status,
      stream_message_id: stream_message_id
    })
  end

  def stream_resolve_response(tool_call_message, decision)
    with_chat_session_tenant_context do
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      message_id = SecureRandom.uuid

      write_sse_event("message_start", { message_id: message_id })

      assistant_message = ChatSessions::ResolveToolCall.call(
        chat_session: @chat_session,
        tool_call_message: tool_call_message,
        decision: decision,
        on_chunk: ->(chunk) { write_sse_event("message_chunk", { message_id: message_id, content: chunk }) },
        on_tool_call_resolved: ->(message) {
          write_sse_event("message_tool_resolved", {
            message_id: message.id,
            tool_status: message.tool_status,
            tool_name: message.tool_name,
            tool_call_id: message.tool_call_id
          })
        },
        on_message_persisted: ->(message, stream_message_id: nil) { write_sse_tool_event(message, stream_message_id: stream_message_id) }
      )

      write_sse_event("message_complete", {
        message_id: message_id,
        tokens: {
          input: assistant_message&.tokens_input,
          output: assistant_message&.tokens_output
        }
      })
    end
  rescue IOError
    # Client disconnected — nothing to send
  rescue NotImplementedError => e
    write_sse_event("error", { message: e.message }) rescue IOError
  rescue ChatSessions::LlmClientConfigurationError => e
    write_sse_event("error", { message: e.message }) rescue IOError
  rescue ArgumentError => e
    write_sse_event("error", { message: e.message }) rescue IOError
  rescue AgentHarness::RateLimitError => e
    write_sse_event("error", { message: ChatSessions::ErrorMessage.for(e) }) rescue IOError
  rescue AgentHarness::Error => e
    write_sse_event("error", { message: ChatSessions::ErrorMessage.for(e) }) rescue IOError
  rescue StandardError => e
    Rails.logger.error(message: "chat_messages.resolve_stream_failed", session_id: @chat_session.id, error: e.message)
    write_sse_event("error", { message: "An unexpected error occurred" }) rescue IOError
  ensure
    response.stream.close
  end

  def json_resolve_response(tool_call_message, decision)
    assistant_message = with_chat_session_tenant_context do
      ChatSessions::ResolveToolCall.call(
        chat_session: @chat_session,
        tool_call_message: tool_call_message,
        decision: decision
      )
    end

    render json: assistant_response_payload(assistant_message), status: :ok
  rescue NotImplementedError => e
    render json: { error: e.message }, status: :service_unavailable
  rescue ChatSessions::LlmClientConfigurationError => e
    render json: { error: e.message }, status: :service_unavailable
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_content
  rescue AgentHarness::RateLimitError => e
    render json: { error: ChatSessions::ErrorMessage.for(e) }, status: :too_many_requests
  rescue AgentHarness::Error => e
    render json: { error: ChatSessions::ErrorMessage.for(e) }, status: :bad_gateway
  rescue StandardError => e
    Rails.logger.error(message: "chat_messages.resolve_failed", session_id: @chat_session.id, error: e.message)
    render json: { error: "An unexpected error occurred" }, status: :internal_server_error
  end

  def with_chat_session_tenant_context(&)
    account = TenantContext.with_system_access do
      Account.find(@chat_session.account_id)
    end
    TenantContext.with(account, &)
  end

  def message_json(message)
    {
      id: message.id,
      external_id: message.external_id,
      role: message.role,
      content: message.content,
      model: message.model,
      tool_call_id: message.tool_call_id,
      tool_name: message.tool_name,
      tool_arguments: message.tool_arguments,
      tool_result: message.tool_result,
      tool_status: message.tool_status,
      tokens_input: message.tokens_input,
      tokens_output: message.tokens_output,
      created_at: message.created_at
    }
  end

  # Returns the persisted assistant message, or a `{ status: "paused" }`
  # payload when the turn paused for a write-tool confirmation (write tools
  # pause the loop and return +nil+ — see ChatSessions::AgentLoop). Shared by
  # the create and resolve JSON paths.
  def assistant_response_payload(assistant_message)
    # @spec CHAT-API-002
    return { status: "paused" } unless assistant_message

    message_json(assistant_message)
  end
end
