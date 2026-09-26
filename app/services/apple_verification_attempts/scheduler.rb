# frozen_string_literal: true

module AppleVerificationAttempts
  # Claims the first admissible fair queue entry and hands it to the caller's
  # guest lifecycle. Quarantine is per worker: a quarantined worker's attempt
  # stays queued while later candidates are considered, so one quarantined
  # profile stops receiving work without stalling every other profile.
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-015
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
      candidates = queue.candidates
      return if candidates.empty?

      snapshot = capacity.call
      result = nil
      candidates.each do |attempt|
        result = admit(attempt, snapshot)
        return result unless result.worker_quarantined?
      end
      result
    end

    private

    attr_reader :capacity, :dispatcher, :queue, :configuration

    def admit(attempt, snapshot)
      result = Admission.call(attempt:, capacity: snapshot, configuration:)
      dispatcher.call(attempt) if result.admitted?
      result
    end
  end
end
