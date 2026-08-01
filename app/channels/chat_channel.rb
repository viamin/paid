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

    # ActionCable channels run outside ApplicationController; TenantContext.with
    # does not propagate the RLS session variable to the query connection here,
    # so role/rate-limit lookups silently come back empty. Bypass RLS and rely
    # on the explicit checks below (Pundit policy + account-scoped session).
    TenantContext.with_system_access do
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

  def resolve_tool_call(data)
    return unless @chat_session

    TenantContext.with_system_access do
      decision = data["decision"].to_s
      message = @chat_session.messages.find_by(id: data["message_id"])
      return transmit_event("error", { message: "Pending tool call not found" }) unless message
      return transmit_event("error", { message: "You are not authorized to resolve tool calls" }) unless authorized_to_resolve?(message)
      return transmit_event("error", { message: "decision must be approve or deny" }) unless %w[approve deny].include?(decision)
      return transmit_event("error", { message: "Rate limit exceeded" }) if rate_limited?

      stream_message_id = SecureRandom.uuid
      broadcast_event("message_start", { message_id: stream_message_id })

      ChatSessions::ResolveToolCallJob.perform_later(
        chat_session_id: @chat_session.id,
        message_id: message.id,
        decision: decision,
        stream_message_id: stream_message_id
      )
    end
  rescue StandardError => e
    Rails.logger.error(message: "chat_channel.resolve_tool_call_failed", session_id: @chat_session&.id, error: e.message)
    transmit_event("error", { message: "An unexpected error occurred" })
  end

  private

  def find_session
    TenantContext.with_system_access do
      ChatSession.where(account_id: current_user.account_id)
        .find_by(id: params[:session_id])
    end
  end

  def stream_name
    "chat_session:#{@chat_session.id}"
  end

  def authorized_to_send_messages?
    ChatMessagePolicy.new(current_user, ChatMessage.new(chat_session: @chat_session)).create?
  end

  def authorized_to_resolve?(message)
    ChatMessagePolicy.new(current_user, message).resolve?
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
