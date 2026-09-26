# frozen_string_literal: true

module AppleVerificationAttempts
  # Claims the first admissible fair queue entry and hands it to the caller's
  # guest lifecycle.
  # @spec APPLE-ATTEMPT-003
  class Scheduler
    def self.call(...)
      new(...).call
    end

    def initialize(capacity:, dispatcher:, queue: Queue)
      @capacity = capacity
      @dispatcher = dispatcher
      @queue = queue
    end

    def call
      attempt = queue.ordered.first
      return unless attempt

      snapshot = capacity.call(attempt:)
      return unless snapshot

      admit(attempt, snapshot)
    end

    private

    attr_reader :capacity, :dispatcher, :queue

    def admit(attempt, snapshot)
      result = Admission.call(
        attempt:,
        capacity: snapshot.capacity,
        active_vms: active_vm_count,
        critical_memory_samples: snapshot.critical_memory_samples
      )
      dispatcher.call(attempt) if result.admitted?
      result
    end

    def active_vm_count
      AppleVerificationAttempt.where(status: %w[provisioning running]).count
    end
  end
end
