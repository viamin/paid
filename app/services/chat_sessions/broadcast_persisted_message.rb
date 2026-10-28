# frozen_string_literal: true

module ChatSessions
  # Broadcasts a persisted chat message to the session's live stream. Shared by
  # the message-processing jobs and by turn recovery so every surface renders
  # the same payload for the same message.
  #
  # @spec CHAT-API-002
  class BroadcastPersistedMessage
    def self.call(stream_name:, message:, stream_message_id: nil)
      ActionCable.server.broadcast(stream_name, payload(message:, stream_message_id:))
    end

    def self.payload(message:, stream_message_id: nil)
      {
        type: event_type(message),
        message_id: message.id,
        role: message.role,
        tool_name: message.tool_name,
        tool_call_id: message.tool_call_id,
        tool_arguments: message.tool_arguments,
        tool_result: message.tool_result,
        fallback_notice: message.fallback_notice?,
        stream_message_id: stream_message_id,
        html: html_for(message)
      }
    end

    def self.event_type(message)
      if message.role == "tool"
        "message_tool_result"
      elsif message.role == "assistant" && message.tool_name.present? && message.content.nil?
        message.pending_confirmation? ? "message_tool_confirmation" : "message_tool_call"
      else
        "message_created"
      end
    end

    def self.html_for(message)
      ApplicationController.render(
        partial: "chat_messages/message",
        locals: { message: message }
      )
    end

    private_class_method :event_type, :html_for
  end
end
