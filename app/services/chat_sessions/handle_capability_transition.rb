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
        sync_capability_notice!
        publish_tools_list_changed
      end
    end

    private

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
      notice = capability_notice
      existing_notice = find_existing_notice

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
        else
          chat_session.messages.create!(**attributes)
        end
      elsif existing_notice
        existing_notice.destroy!
      end
    end

    def find_existing_notice
      chat_session.messages.where(role: "system").find do |message|
        message.metadata.is_a?(Hash) && message.metadata["container_capability_notice"] == true
      end
    end

    def capability_notice
      case to
      when "failed"
        "Workspace tools are currently unavailable because the workspace container failed to prepare. Use inline tools until the workspace is restored."
      when "stopped"
        "Workspace tools are currently unavailable because the workspace container is stopped. Use inline tools until the workspace is started again."
      end
    end
  end
end
