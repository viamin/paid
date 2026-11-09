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
      volume_names.each { |name| cleanup_volume_resource(name) }
    end

    private

    def cleanup_container_resource
      container = backend.get_container(chat_session.container_id)
      stop_container(container)
      backend.delete_container(container, force: true, v: true)
    rescue Docker::Error::NotFoundError
      nil
    rescue Docker::Error::DockerError => error
      Rails.logger.warn(
        message: "chat_session.container_cleanup_failed",
        chat_session_id: chat_session.id,
        container_id: chat_session.container_id,
        error_class: error.class.name,
        error: error.message
      )
    end

    def stop_container(container)
      backend.stop_container(container, timeout: 0)
    rescue Docker::Error::NotFoundError, Docker::Error::ClientError
      nil
    end

    def volume_names
      [ chat_session.workspace_volume, "paid-chat-state-#{chat_session.id}" ].compact.uniq
    end

    def cleanup_volume_resource(name)
      backend.delete_volume(backend.get_volume(name))
    rescue Docker::Error::NotFoundError
      nil
    rescue Docker::Error::DockerError => error
      Rails.logger.warn(
        message: "chat_session.volume_cleanup_failed",
        chat_session_id: chat_session.id,
        volume_name: name,
        error_class: error.class.name,
        error: error.message
      )
    end

    def backend
      Containers.backend
    end
  end
end
