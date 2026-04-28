# frozen_string_literal: true

module ChatSessions
  # Checks whether a chat session is within its token limits.
  # Evaluates both per-session and per-account monthly limits,
  # returning the more restrictive result.
  #
  # @example
  #   result = ChatSessions::CheckTokenLimit.call(chat_session: session)
  #   result[:within_limit]     # => true
  #   result[:remaining_tokens] # => 95000
  #   result[:limit]            # => 100000
  #   result[:limit_type]       # => "session"
  class CheckTokenLimit
    attr_reader :chat_session

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def self.call(...)
      new(...).call
    end

    def call
      session_result = check_session_limit
      monthly_result = check_monthly_limit

      more_restrictive(session_result, monthly_result)
    end

    private

    def check_session_limit
      limit = session_token_limit
      return unlimited_result("session") if limit.nil?

      used = chat_session.total_tokens
      remaining = [ limit - used, 0 ].max

      {
        within_limit: used < limit,
        remaining_tokens: remaining,
        limit: limit,
        limit_type: "session"
      }
    end

    def check_monthly_limit
      limit = monthly_token_limit
      return unlimited_result("monthly") if limit.nil?

      used = monthly_chat_tokens_used
      remaining = [ limit - used, 0 ].max

      {
        within_limit: used < limit,
        remaining_tokens: remaining,
        limit: limit,
        limit_type: "monthly"
      }
    end

    def more_restrictive(a, b)
      return b if a[:limit].nil?
      return a if b[:limit].nil?

      a[:remaining_tokens] <= b[:remaining_tokens] ? a : b
    end

    def unlimited_result(limit_type)
      { within_limit: true, remaining_tokens: nil, limit: nil, limit_type: limit_type }
    end

    def session_token_limit
      tenant_setting&.chat_session_token_limit
    end

    def monthly_token_limit
      tenant_setting&.chat_monthly_token_limit
    end

    def tenant_setting
      @tenant_setting ||= chat_session.account.tenant_setting
    end

    def monthly_chat_tokens_used
      beginning_of_month = Time.current.beginning_of_month
      TokenUsage.where(request_type: "chat_message")
        .joins(:chat_session)
        .where(chat_sessions: { account_id: chat_session.account_id })
        .where(created_at: beginning_of_month..)
        .sum(Arel.sql("input_tokens + output_tokens"))
    end
  end
end
