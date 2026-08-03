# frozen_string_literal: true

module ChatSessions
  class ReapIdleWorkspace
    attr_reader :chat_session

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def call
      return chat_session if chat_session.inline_only?

      if chat_session.container_id.present? || chat_session.workspace_volume.present?
        Containers::ChatSessionManager.new(chat_session).cleanup!(preserve_state: true)
      else
        chat_session.update!(
          container_capability: "stopped",
          container_id: nil,
          workspace_volume: nil
        )
      end

      chat_session.update!(idle_timeout_at: nil)
      chat_session
    end
  end
end
