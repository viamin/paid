# frozen_string_literal: true

module ChatSessions
  # Records a non-rate-limit failure from an unattended resend. The original
  # rate-limit marker has already been cleared; do not recreate it because
  # authentication and configuration failures need human intervention.
  class RecordProviderError
    attr_reader :chat_session, :error

    def initialize(chat_session:, error:)
      @chat_session = chat_session
      @error = error
    end

    def self.call(...)
      new(...).call
    end

    def call
      # @spec CHAT-API-017
      built = ProviderErrorNotice.build(error: error)
      chat_session.messages.create!(role: "system", content: built.content, metadata: built.metadata)
    end
  end
end
