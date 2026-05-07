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
      content = data["content"].to_s
      return if content.blank?
      return transmit_event("error", { message: "You are not authorized to send messages" }) unless authorized_to_send_messages?
      return transmit_event("error", { message: "Rate limit exceeded" }) if rate_limited?
      if content.length > ChatSessions::SendMessage::MAX_CONTENT_LENGTH
        return transmit_event("error", { message: "Message exceeds maximum length" })
      end

      stream_message_id = SecureRandom.uuid
      broadcast_event("message_start", { message_id: stream_message_id, model: @chat_session.model })

      ChatSessions::ProcessMessageJob.perform_later(
        chat_session_id: @chat_session.id,
        content: content,
        stream_message_id: stream_message_id
      )
    end
  rescue StandardError => e
    Rails.logger.error(message: "chat_channel.send_message_failed", session_id: @chat_session&.id, error: e.message)
    transmit_event("error", { message: "An unexpected error occurred" })
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

  def authorized_to_send_messages?
    ChatMessagePolicy.new(current_user, ChatMessage.new(chat_session: @chat_session)).create?
  end

  def rate_limited?
    ChatMessages::RateLimit.exceeded?(user_id: current_user.id, chat_session_id: @chat_session.id)
  end

  def broadcast_event(type, data)
    ActionCable.server.broadcast(stream_name, { type: type }.merge(data))
  end

  def transmit_event(type, data)
    transmit({ type: type }.merge(data))
  end
end
