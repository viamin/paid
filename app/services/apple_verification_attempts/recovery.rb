# frozen_string_literal: true

module AppleVerificationAttempts
  # Reconciles crash-window resources and applies overdue-attempt recovery.
  # @spec APPLE-ATTEMPT-014
  class Recovery
    Result = Data.define(:reconciliation, :timed_out_attempts)

    def self.call(...)
      new(...).call
    end

    def initialize(reconciler: ExecutionRunners::ResourceReconciler, timeout_monitor: TimeoutMonitor)
      @reconciler = reconciler
      @timeout_monitor = timeout_monitor
    end

    def call
      Result.new(reconciliation: reconciler.call, timed_out_attempts: timeout_monitor.call)
    end

    private

    attr_reader :reconciler, :timeout_monitor
  end
end
