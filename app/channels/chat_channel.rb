# frozen_string_literal: true

class ChatChannel < ApplicationCable::Channel
  def subscribed
    session = find_session
    if session
      @chat_session = session
      stream_from stream_name
    else
      reject
    end
  end

  def unsubscribed
    stop_all_streams
  end

  def send_message(data)
    return unless @chat_session

    TenantContext.with(current_user.account) do
      content = data["content"]
      return if content.blank?

      message_id = SecureRandom.uuid
      broadcast_event("message_start", { message_id: message_id, model: @chat_session.model })

      assistant_message = ChatSessions::SendMessage.call(
        chat_session: @chat_session,
        content: content,
        on_chunk: ->(chunk) {
          broadcast_event("message_chunk", { message_id: message_id, content: chunk })
        }
      )

      broadcast_event("message_complete", {
        message_id: message_id,
        tokens: {
          input: assistant_message.tokens_input,
          output: assistant_message.tokens_output
        }
      })
    end
  rescue ArgumentError => e
    broadcast_event("error", { message: e.message })
  rescue StandardError => e
    Rails.logger.error(message: "chat_channel.send_message_failed", session_id: @chat_session.id, error: e.message)
    broadcast_event("error", { message: "An unexpected error occurred" })
  end

  private

  def find_session
    TenantContext.with(current_user.account) do
      ChatSession.where(account: current_user.account)
        .find_by(id: params[:session_id])
    end
  end

  def stream_name
    "chat_session:#{@chat_session.id}"
  end

  def broadcast_event(type, data)
    ActionCable.server.broadcast(stream_name, { type: type }.merge(data))
  end
end
