# frozen_string_literal: true

module ChatSessions
  class Unarchive
    attr_reader :chat_session

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!

      chat_session.update!(restore_attributes)

      chat_session
    end

    private

    def validate!
      return if chat_session.status == "archived"

      raise ArgumentError, "chat session must be archived to restore (current: #{chat_session.status})"
    end

    def restore_attributes
      {
        status: "active",
        idle_timeout_at: ChatSession::IDLE_TIMEOUT_DURATION.from_now,
        metadata: (chat_session.metadata || {}).merge("unarchived_at" => Time.current.iso8601)
      }
    end
  end
end
