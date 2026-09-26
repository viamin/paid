# frozen_string_literal: true

module AppleVerificationAttempts
  # Reconciles in-flight attempts whose verification VM is provably gone or
  # orphaned after a control-plane/host restart or partial provisioning
  # failure. Each affected attempt converges to `unavailable` (worker
  # infrastructure) so it is retired, retried, or waived rather than left
  # running indefinitely. Idempotent: once `complete` moves an attempt to a
  # terminal state, a subsequent scan never sees it again.
  # @spec APPLE-ATTEMPT-014
  class Recovery
    Result = Data.define(:reconciled, :scanned)

    IN_FLIGHT_STATUSES = %w[provisioning running].freeze
    LIVE_STATUSES = %w[provisioning active cleanup_pending orphaned cleanup_failed].freeze

    def self.call(now: Time.current, complete: nil)
      new(now: now, complete: complete).call
    end

    def initialize(now:, complete:)
      @now = now
      @complete = complete || AppleVerificationAttempts::Complete
    end

    def call
      reconciled = 0
      scanned = 0

      AppleVerificationAttempt.where(status: IN_FLIGHT_STATUSES).find_each do |attempt|
        scanned += 1
        reconciled += 1 if reconcile?(attempt)
      end

      Result.new(reconciled: reconciled, scanned: scanned)
    end

    private

    def reconcile?(attempt)
      attempt.with_lock do
        attempt.reload
        reconcile_locked_attempt?(attempt)
      end
    end

    def reconcile_locked_attempt?(attempt)
      return false unless attempt.status.in?(IN_FLIGHT_STATUSES)

      entries = attempt.execution_resource_ledger_entries.where(resource_kind: "verification_vm")
      return false unless entries.where(status: LIVE_STATUSES).empty? || entries.where(status: "orphaned").exists?

      @complete.call(attempt: attempt, outcome: "unavailable", failure_classification: "worker_infrastructure")
      true
    end
  end
end
