# frozen_string_literal: true

module ChatSessions
  # Builds the persisted system-message content and metadata explaining that a
  # chat session was paused because every configured runner (the primary
  # runner and all fallbacks) hit a provider rate limit (CHAT-API-017). Mirrors
  # ChatSessions::TokenLimitErrorMessage so the explanation survives reload
  # instead of living only in a transient status string.
  class RateLimitPauseMessage
    Result = Data.define(:content, :metadata)

    def self.build(reset_at:, auto_resume:)
      new(reset_at: reset_at, auto_resume: auto_resume).build
    end

    def initialize(reset_at:, auto_resume:)
      @reset_at = reset_at
      @auto_resume = auto_resume
    end

    def build
      Result.new(content: content, metadata: metadata)
    end

    private

    attr_reader :reset_at, :auto_resume

    def content
      [ headline, guidance ].compact.join("\n\n")
    end

    def headline
      "Chat paused: the runner hit a rate limit#{reset_at_clause}."
    end

    def reset_at_clause
      return "" unless reset_at

      " (resets at #{I18n.l(reset_at, format: :long)})"
    end

    def guidance
      if auto_resume
        "Your last message will be resent automatically once the rate limit clears."
      else
        "Automatic resend is disabled for this account. Send your message again once the rate limit clears, " \
          "or ask an administrator to enable automatic resumption."
      end
    end

    def metadata
      {
        "rate_limit_paused" => true,
        "reset_at" => reset_at&.iso8601,
        "auto_resume" => auto_resume
      }.compact
    end
  end
end
