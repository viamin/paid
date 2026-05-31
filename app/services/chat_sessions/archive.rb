# frozen_string_literal: true

module ChatSessions
  class Archive
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
        compute_totals if active_or_idle?
        cleanup_workspace_resources if active_or_idle? && workspace_session?
        chat_session.update!(archive_attributes)
      end

      chat_session
    end

    private

    def validate!
      return if %w[active idle closed].include?(chat_session.status)

      raise ArgumentError, "chat session must be active, idle, or closed to archive (current: #{chat_session.status})"
    end

    def active_or_idle?
      %w[active idle].include?(chat_session.status)
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
        "total_messages" => totals[3]
      )
    end

    def archive_attributes
      {
        status: "archived",
        idle_timeout_at: nil,
        metadata: (chat_session.metadata || {}).merge("archived_at" => Time.current.iso8601)
      }.merge(workspace_cleanup_attributes)
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
      Rails.logger.info(
        message: "chat_session.cleanup_container",
        chat_session_id: chat_session.id,
        container_id: chat_session.container_id
      )
    end

    def cleanup_volume_resource
      Rails.logger.info(
        message: "chat_session.cleanup_volume",
        chat_session_id: chat_session.id,
        workspace_volume: chat_session.workspace_volume
      )
    end
  end
end
