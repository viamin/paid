# frozen_string_literal: true

module AppleVerificationAttempts
  # Cancels an attempt that has not reached a terminal lifecycle state.
  # @spec APPLE-VERIFY-006
  class Cancel
    def self.call(attempt:)
      new(attempt:).call
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      raise ArgumentError, "attempt is no longer active" unless @attempt.cancellable?

      @attempt.update!(status: "cancelled", finished_at: Time.current)
    end
  end
end
