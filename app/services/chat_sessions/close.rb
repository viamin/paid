# frozen_string_literal: true

module ChatSessions
  # Gracefully closes a chat session: transitions status to "closed",
  # computes final token/cost totals, and cleans up workspace resources.
  #
  # @example
  #   ChatSessions::Close.call(chat_session: session)
  class Close
    attr_reader :chat_session

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!

      ActiveRecord::Base.transaction do
        compute_totals
        transition_to_closed
        cleanup_workspace if chat_session.mode == "workspace"
      end

      chat_session
    end

    private

    def validate!
      return if %w[active idle].include?(chat_session.status)

      raise ArgumentError, "chat session must be active or idle to close (current: #{chat_session.status})"
    end

    def compute_totals
      totals = chat_session.messages.where.not(tokens_input: nil).pick(
        Arel.sql("COALESCE(SUM(tokens_input), 0)"),
        Arel.sql("COALESCE(SUM(tokens_output), 0)")
      )

      chat_session.metadata ||= {}
      chat_session.metadata["total_tokens_input"] = totals[0]
      chat_session.metadata["total_tokens_output"] = totals[1]
      chat_session.metadata["total_messages"] = chat_session.messages.count
      chat_session.metadata["closed_at"] = Time.current.iso8601
    end

    def transition_to_closed
      chat_session.update!(status: "closed")
    end

    def cleanup_workspace
      cleanup_container if chat_session.container_id.present?
      cleanup_volume if chat_session.workspace_volume.present?
    end

    def cleanup_container
      # Placeholder for container cleanup via Containers::Provision or Docker API.
      # In production, this destroys the persistent workspace container.
      Rails.logger.info(
        message: "chat_session.cleanup_container",
        chat_session_id: chat_session.id,
        container_id: chat_session.container_id
      )
      chat_session.update!(container_id: nil)
    end

    def cleanup_volume
      # Placeholder for volume cleanup.
      # In production, this removes the persistent workspace volume.
      Rails.logger.info(
        message: "chat_session.cleanup_volume",
        chat_session_id: chat_session.id,
        workspace_volume: chat_session.workspace_volume
      )
      chat_session.update!(workspace_volume: nil)
    end
  end
end
