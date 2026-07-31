# frozen_string_literal: true

module ChatSessions
  # Reopens a closed API chat session so the same thread can continue later.
  # Container-backed sessions remain non-resumable because close tears down resources.
  class Resume
    CLOSE_SNAPSHOT_KEYS = %w[
      total_tokens_input
      total_tokens_output
      total_cost_cents
      total_messages
      closed_at
    ].freeze

    attr_reader :chat_session

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def self.call(...)
      new(...).call
    end

    def call
      chat_session.with_lock do
        chat_session.reload
        validate!
        resume! if chat_session.status == "closed"
      end

      chat_session
    end

    private

    def validate!
      raise ArgumentError, "container-backed chat sessions cannot be resumed" unless chat_session.inline_only?
      return if %w[active closed].include?(chat_session.status)

      raise ArgumentError, "chat session must be active or closed to resume"
    end

    def resume!
      chat_session.update!(
        status: "active",
        idle_timeout_at: ChatSession::IDLE_TIMEOUT_DURATION.from_now,
        metadata: resumed_metadata
      )
    end

    def resumed_metadata
      metadata = (chat_session.metadata || {}).deep_dup
      CLOSE_SNAPSHOT_KEYS.each { |key| metadata.delete(key) }
      metadata["last_resumed_at"] = Time.current.iso8601
      metadata["resume_count"] = metadata.fetch("resume_count", 0).to_i + 1
      metadata
    end
  end
end
