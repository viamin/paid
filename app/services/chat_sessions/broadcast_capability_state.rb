# frozen_string_literal: true

module ChatSessions
  class BroadcastCapabilityState
    attr_reader :chat_session

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def call
      ActionCable.server.broadcast("chat_session:#{chat_session.id}", CapabilitySnapshot.call(chat_session:))
    end
  end
end
