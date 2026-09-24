# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-014
  # Idempotently reconciles Apple verification attempts after a control
  # plane restart, host restart, network interruption, timeout, or partial
  # provisioning failure. Every recover/reset operation is safe to call
  # twice: attempts in non-terminal states get classified into their
  # terminal failure buckets (cancellation_or_timeout or worker_infrastructure
  # as appropriate), and the durable external-resource ledger entries are
  # the source of truth for the VM inventory reconciliation that follows.
  class Recovery
    Result = Data.define(:scanned, :reclassified, :orphans)

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      attempt_scope: AppleVerificationAttempt,
      timeout_monitor: TimeoutMonitor.new(attempt_scope:),
      ledger_reconciler: ExecutionRunners::ResourceReconciler,
      completion: Complete,
      clock: Time
    )
      @attempt_scope = attempt_scope
      @timeout_monitor = timeout_monitor
      @ledger_reconciler = ledger_reconciler
      @completion = completion
      @clock = clock
    end

    def call
      timeout_result = @timeout_monitor.call
      reclassified = timeout_result.timed_out
      finalize_incomplete_terminal_attempts

      Result.new(
        scanned: timeout_result.scanned,
        reclassified: reclassified,
        orphans: reconcile_orphans
      )
    end

    # Drives the durable ledger reconciler so any orphaned Paid-owned VMs
    # (from a partial provisioning, a host restart, or a control-plane
    # restart) are quarantined or destroyed per their ledger state. The
    # reconciler is itself idempotent — repeat calls during a restart loop
    # add no duplicate cleanup work — so this method is safe to call from
    # both the on-boot recovery job and a periodic sweep.
    def reconcile_orphans
      @ledger_reconciler.call
    rescue StandardError => error
      Rails.logger.warn(
        message: "apple_verification_attempts.recovery_orchestrator_failed",
        error_class: error.class.name,
        error: error.message
      )
      { enqueued: 0, cleaned: 0, failed: 0 }
    end

    def finalize_incomplete_terminal_attempts
      @attempt_scope
        .where(status: %w[failed cancelled timed_out unavailable], container_retained_until: nil)
        .find_each { |attempt| @completion.call(attempt:) }
    end
  end
end
