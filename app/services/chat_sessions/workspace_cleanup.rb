# frozen_string_literal: true

module ChatSessions
  class WorkspaceCleanup
    attr_reader :chat_session

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def self.call(...)
      new(...).call
    end

    def call
      # @spec CHAT-API-030
      cleanup_container_resource if chat_session.container_id.present?
      cleanup_volume_resource if chat_session.workspace_volume.present?
    end

    private

    def cleanup_container_resource
      # Placeholder for container cleanup via Containers::Provision or Docker API.
      # In production, this destroys the persistent workspace container.
      Rails.logger.info(
        message: "chat_session.cleanup_container",
        chat_session_id: chat_session.id,
        container_id: chat_session.container_id
      )
    end

    def cleanup_volume_resource
      # Placeholder for volume cleanup.
      # In production, this removes the persistent workspace volume.
      Rails.logger.info(
        message: "chat_session.cleanup_volume",
        chat_session_id: chat_session.id,
        workspace_volume: chat_session.workspace_volume
      )
    end
  end
end
