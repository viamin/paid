# frozen_string_literal: true

class ChatMessagesController < ApplicationController
  include ActionController::Live

  skip_after_action :verify_authorized, only: :index
  before_action :set_chat_session

  rate_limit to: 60, within: 1.minute,
    by: -> { "#{current_user&.id}:#{params[:chat_session_id]}" },
    with: -> { render json: { error: "Rate limit exceeded" }, status: :too_many_requests },
    only: :create

  def index
    messages = policy_scope(ChatMessage)
      .where(chat_session: @chat_session)

    messages = messages.where(role: params[:role]) if params[:role].present?
    messages = messages.where("chat_messages.id < ?", params[:before]) if params[:before].present?

    messages = messages.order(created_at: :desc).limit(50)

    render json: messages.reverse.map { |m| message_json(m) }
  end

  def create
    authorize @chat_session.messages.build(chat_session: @chat_session), policy_class: ChatMessagePolicy

    if params[:content].blank?
      render json: { error: "content is required" }, status: :unprocessable_content
      return
    end

    if sse_requested?
      stream_sse_response
    else
      json_response
    end
  end

  private

  def set_chat_session
    @chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
  end

  def sse_requested?
    request.headers["Accept"]&.include?("text/event-stream")
  end

  def stream_sse_response
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    message_id = SecureRandom.uuid

    write_sse_event("message_start", { message_id: message_id, model: @chat_session.model })

    assistant_message = ChatSessions::SendMessage.call(
      chat_session: @chat_session,
      content: params[:content],
      on_chunk: ->(chunk) { write_sse_event("message_chunk", { message_id: message_id, content: chunk }) }
    )

    write_sse_event("message_complete", {
      message_id: message_id,
      tokens: {
        input: assistant_message.tokens_input,
        output: assistant_message.tokens_output
      }
    })
  rescue ArgumentError => e
    write_sse_event("error", { message: e.message })
  rescue StandardError => e
    Rails.logger.error(message: "chat_messages.stream_failed", session_id: @chat_session.id, error: e.message)
    write_sse_event("error", { message: "An unexpected error occurred" })
  ensure
    response.stream.close
  end

  def json_response
    assistant_message = ChatSessions::SendMessage.call(
      chat_session: @chat_session,
      content: params[:content]
    )
    render json: message_json(assistant_message), status: :created
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_content
  rescue StandardError => e
    Rails.logger.error(message: "chat_messages.send_failed", session_id: @chat_session.id, error: e.message)
    render json: { error: "An unexpected error occurred" }, status: :internal_server_error
  end

  def write_sse_event(event, data)
    response.stream.write("event: #{event}\ndata: #{data.to_json}\n\n")
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
      tokens_input: message.tokens_input,
      tokens_output: message.tokens_output,
      created_at: message.created_at
    }
  end
end
