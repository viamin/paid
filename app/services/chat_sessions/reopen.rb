# frozen_string_literal: true

module ChatSessions
  class Reopen
    attr_reader :chat_session

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def call
      enqueue = false

      chat_session.with_lock do
        chat_session.reload
        validate!
        return chat_session if chat_session.container_ready? || chat_session.container_pending? || chat_session.container_provisioning?

        chat_session.update!(
          status: "active",
          container_capability: "pending",
          container_requested_at: Time.current,
          container_ready_at: nil,
          metadata: resumed_metadata
        )
        enqueue = true
      end

      ChatSessions::ProvisionContainerJob.perform_later(chat_session_id: chat_session.id) if enqueue
      chat_session
    end

    private

    def validate!
      raise ArgumentError, "chat session must not be archived" if chat_session.archived?
      return unless chat_session.inline_only?

      raise ArgumentError, "inline-only chat sessions do not have a workspace to reopen"
    end

    def resumed_metadata
      metadata = (chat_session.metadata || {}).deep_dup
      ChatSessions::Resume::CLOSE_SNAPSHOT_KEYS.each { |key| metadata.delete(key) }
      metadata["last_reopened_at"] = Time.current.iso8601
      metadata["workspace_reopen_requested_at"] = Time.current.iso8601
      metadata["reopen_count"] = metadata.fetch("reopen_count", 0).to_i + 1
      metadata
    end
  end
end
