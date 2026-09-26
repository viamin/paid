# frozen_string_literal: true

module AppleVerificationAttempts
  # Ends overdue attempts as infrastructure timeouts and requests VM cleanup.
  # @spec APPLE-ATTEMPT-004
  class TimeoutMonitor
    def self.call(...)
      new(...).call
    end

    def initialize(configuration: Configuration.new, cancellation: Cancel, lifecycle: AppleVerification::Lifecycle.from_environment, clock: Time)
      @configuration = configuration
      @cancellation = cancellation
      @lifecycle = lifecycle
      @clock = clock
    end

    def call
      overdue.find_each.map { |attempt| timeout(attempt) }
    end

    private

    attr_reader :configuration, :cancellation, :lifecycle, :clock

    def overdue
      AppleVerificationAttempt.where(status: %w[provisioning running])
        .where("started_at <= ?", clock.current - configuration.attempt_timeout)
    end

    def timeout(attempt)
      cancellation.call(attempt:, outcome: "timed_out", lifecycle:, clock:)
    end
  end
end
