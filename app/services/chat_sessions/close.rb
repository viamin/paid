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

      return destroy_empty_session unless user_messages?

      ActiveRecord::Base.transaction do
        compute_totals
        cleanup_workspace_resources if workspace_session?
        transition_to_closed(workspace_cleanup_attributes)
      end

      chat_session
    end

    private

    def validate!
      return if %w[active idle].include?(chat_session.status)

      raise ArgumentError, "chat session must be active or idle to close (current: #{chat_session.status})"
    end

    def destroy_empty_session
      cleanup_workspace_resources if workspace_session?
      chat_session.destroy!
      chat_session
    end

    def user_messages?
      chat_session.messages.where(role: "user").exists?
    end

    def workspace_session?
      chat_session.mode == "workspace"
    end

    def compute_totals
      totals = TenantContext.with_system_access do
        [
          TokenUsage.where(chat_session_id: chat_session.id).sum(:input_tokens),
          TokenUsage.where(chat_session_id: chat_session.id).sum(:output_tokens),
          TokenUsage.where(chat_session_id: chat_session.id).sum(:cost_cents),
          ChatMessage.where(chat_session_id: chat_session.id).count
        ]
      end

      chat_session.metadata = (chat_session.metadata || {}).merge(
        "total_tokens_input" => totals[0],
        "total_tokens_output" => totals[1],
        "total_cost_cents" => totals[2],
        "total_messages" => totals[3],
        "closed_at" => Time.current.iso8601
      )
    end

    def transition_to_closed(attributes = {})
      chat_session.update!({ status: "closed" }.merge(attributes))
    end

    def workspace_cleanup_attributes
      return {} unless workspace_session?

      {
        container_id: nil,
        workspace_volume: nil
      }
    end

    def cleanup_workspace_resources
      cleanup_container_resource if chat_session.container_id.present?
      cleanup_volume_resource if chat_session.workspace_volume.present?
    end

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
