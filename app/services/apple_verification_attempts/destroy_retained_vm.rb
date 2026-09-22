# frozen_string_literal: true

module AppleVerificationAttempts
  # Requests early cleanup for the retained VM resources of a failed attempt.
  # @spec APPLE-VERIFY-006
  class DestroyRetainedVm
    def self.call(attempt:)
      new(attempt:).call
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      raise ArgumentError, "only a failed attempt can have a retained VM" unless @attempt.failed?

      resources = retained_resources.to_a
      raise ArgumentError, "attempt has no retained VM" if resources.empty?

      resources.each(&:request_cleanup!)
    end

    private

    def retained_resources
      @attempt.execution_resource_ledger_entries.where(resource_kind: "verification_vm", status: %w[active cleanup_failed orphaned])
    end
  end
end
