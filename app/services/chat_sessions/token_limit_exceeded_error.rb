# frozen_string_literal: true

module ChatSessions
  class TokenLimitExceededError < StandardError
    attr_reader :remaining, :limit, :limit_type

    def initialize(message = "Chat token limit exceeded", remaining: 0, limit: nil, limit_type: nil)
      @remaining = remaining
      @limit = limit
      @limit_type = limit_type
      super(message)
    end
  end
end
