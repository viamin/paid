# frozen_string_literal: true

module ChatSessions
  # Pauses a chat session after every configured runner (the primary runner
  # and all fallbacks) has been exhausted by a provider rate limit
  # (CHAT-API-017): FallbackLoop#run_with_fallbacks re-raises
  # AgentHarness::RateLimitError only once no untried fallback remains, so by
  # the time this runs the session genuinely has nothing left to try until the
  # rate limit clears.
  #
  # Persists a durable, visible explanation (mirrors
  # ChatSessions::TokenLimitErrorMessage) and records +rate_limited_until+ so
  # ChatSessions::AutoResumeRateLimitedSweepJob can find and resume the
  # session once the window elapses.
  class MarkRateLimited
    attr_reader :chat_session, :error

    def initialize(chat_session:, error:)
      @chat_session = chat_session
      @error = error
    end

    def self.call(...)
      new(...).call
    end

    def call
      chat_session.mark_rate_limited!(reset_at: reset_at)

      built = RateLimitPauseMessage.build(reset_at: reset_at, auto_resume: auto_resume?)
      chat_session.messages.create!(role: "system", content: built.content, metadata: built.metadata)
    end

    private

    def reset_at
      @reset_at ||= error.respond_to?(:reset_time) ? error.reset_time : nil
    end

    def auto_resume?
      chat_session.auto_resume_rate_limited?
    end
  end
end
