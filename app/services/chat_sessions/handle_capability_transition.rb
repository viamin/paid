# frozen_string_literal: true

module ChatSessions
  class HandleCapabilityTransition
    attr_reader :chat_session, :from, :to

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:, from:, to:)
      @chat_session = chat_session
      @from = from
      @to = to
    end

    def call
      TenantContext.with(chat_session.account) do
        notice_message, deleted_notice_id = sync_capability_notice!
        broadcast_capability_changed
        broadcast_notice_message(notice_message) if notice_message
        broadcast_deleted_notice(deleted_notice_id) if deleted_notice_id
        publish_tools_list_changed
      end
    end

    private

    def broadcast_capability_changed
      ActionCable.server.broadcast("chat_session:#{chat_session.id}", {
        type: "capability_changed",
        container_capability: to,
        container_ready_at: chat_session.container_ready_at
      })
    end

    def publish_tools_list_changed
      Mcp::SessionTransport.publish(
        session_id: chat_session.id,
        event: "message",
        data: PaidMcpServer.tools_list_changed_notification(
          session: chat_session,
          from: from,
          to: to
        )
      )
    end

    def sync_capability_notice!
      return if intentional_teardown_stop_transition?

      notice = capability_notice
      existing_notice = chat_session.messages.container_capability_notices.first

      if notice.present?
        attributes = {
          role: "system",
          content: notice,
          metadata: {
            "container_capability_notice" => true,
            "container_capability" => to
          }
        }

        if existing_notice
          existing_notice.update!(**attributes)
          [ existing_notice, nil ]
        else
          [ chat_session.messages.create!(**attributes), nil ]
        end
      elsif existing_notice
        deleted_notice_id = existing_notice.id
        existing_notice.destroy!
        [ nil, deleted_notice_id ]
      else
        [ nil, nil ]
      end
    end

    def capability_notice
      Containers::CapabilityMessages.notice_for(to)
    end

    def intentional_teardown_stop_transition?
      to == "stopped" && %w[closed archived].include?(chat_session.status)
    end

    def broadcast_notice_message(message)
      ActionCable.server.broadcast("chat_session:#{chat_session.id}", {
        type: "message_created",
        message_id: message.id,
        role: message.role,
        fallback_notice: message.fallback_notice?,
        html: ApplicationController.render(
          partial: "chat_messages/message",
          locals: { message: message }
        )
      })
    end

    def broadcast_deleted_notice(message_id)
      ActionCable.server.broadcast("chat_session:#{chat_session.id}", {
        type: "message_deleted",
        message_id: message_id
      })
    end
  end
end
