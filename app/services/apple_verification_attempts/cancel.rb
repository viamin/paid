# frozen_string_literal: true

module AppleVerificationAttempts
  # Cancels an attempt that has not reached a terminal lifecycle state and
  # revokes its credential lane before recording the terminal state. It then
  # converges any live VM ledger entries toward cleanup so a cancelled
  # in-flight attempt cannot leave a running verification VM behind.
  # @spec APPLE-VERIFY-006
  # @spec APPLE-ATTEMPT-014
  # @spec APPLE-ATTEMPT-009
  class Cancel
    LIVE_VM_STATUSES = %w[provisioning active cleanup_pending cleanup_failed orphaned].freeze

    def self.call(attempt:)
      new(attempt:).call
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      @attempt.with_lock do
        raise ArgumentError, "attempt is no longer active" unless @attempt.cancellable?

        AppleVerificationAttempts::Complete.call(
          attempt: @attempt,
          outcome: "cancelled",
          failure_classification: "cancellation_or_timeout"
        )
        converge_vm_ledger!
      end
    end

    private

    # Idempotent: `request_cleanup!` is a no-op on an already-cleanup-pending
    # entry, and a second cancel raises before touching the ledger again. The
    # durable cleanup queue (ResourceReconciler) drives the real host destroy.
    def converge_vm_ledger!
      @attempt.execution_resource_ledger_entries
        .where(resource_kind: "verification_vm", status: LIVE_VM_STATUSES)
        .each(&:request_cleanup!)
    end
  end
end
