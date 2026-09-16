# frozen_string_literal: true

module ChatSessions
  # Builds the persisted system-message content and metadata for a chat
  # token-limit rejection, so the explanation for why a send failed lives in
  # the conversation history (survives reload) instead of only in a
  # transient status string (#3847).
  class TokenLimitErrorMessage
    Result = Data.define(:content, :metadata)

    def self.build(limit_type:, limit:, used:)
      new(limit_type: limit_type, limit: limit, used: used).build
    end

    def initialize(limit_type:, limit:, used:)
      @limit_type = limit_type
      @limit = limit
      @used = used
    end

    def build
      Result.new(content: content, metadata: metadata)
    end

    private

    attr_reader :limit_type, :limit, :used

    def content
      [ headline, usage_line, guidance ].compact.join("\n\n")
    end

    def headline
      monthly? ? "Monthly chat token limit reached." : "Session chat token limit reached."
    end

    def usage_line
      return if limit.nil? || used.nil?

      "Used #{delimited(used)} of #{delimited(limit)} tokens allowed."
    end

    def guidance
      if monthly?
        "This limit resets at the start of next month. Starting a new chat session will not help — " \
          "ask an administrator to increase the account's monthly chat token limit if you need to continue now."
      else
        "Start a new chat session to continue, or ask an administrator to increase the configured " \
          "session token limit."
      end
    end

    def monthly?
      limit_type == "monthly"
    end

    def delimited(number)
      ActiveSupport::NumberHelper.number_to_delimited(number)
    end

    def metadata
      {
        "token_limit_error" => true,
        "limit_type" => limit_type,
        "limit" => limit,
        "used_tokens" => used
      }.compact
    end
  end
end
