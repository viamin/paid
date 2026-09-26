# frozen_string_literal: true

module AppleVerificationAttempts
  # Claims one fair queue entry and hands it to the caller's guest lifecycle.
  # @spec APPLE-ATTEMPT-003
  class Scheduler
    def self.call(...)
      new(...).call
    end

    def initialize(capacity:, dispatcher:, queue: Queue.new, configuration: Configuration.new)
      @capacity = capacity
      @dispatcher = dispatcher
      @queue = queue
      @configuration = configuration
    end

    def call
      attempt = queue.next
      return unless attempt

      result = Admission.call(attempt:, capacity: capacity.call, configuration:)
      dispatcher.call(attempt) if result.admitted?
      result
    end

    private

    attr_reader :capacity, :dispatcher, :queue, :configuration
  end
end
