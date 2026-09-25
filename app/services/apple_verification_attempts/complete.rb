# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-006
  # Finalises a terminal Apple verification attempt: revokes the attempt's
  # credentials, disables the attempt's network authority, and either
  # destroys a successful VM immediately or records the failed-VM retention
  # window (default one hour, configurable). Operators can request an
  # earlier destroy via {#early_destroy_retained_vm}, which routes through
  # the {AppleVerification::Lifecycle} boundary so the audit event reflects
  # a real destroy rather than a no-op.
  class Complete
    DEFAULT_FAILED_VM_RETENTION_HOURS = 1

    Result = Data.define(:outcome, :retained_until, :destroy_request_id)

    OUTCOME_DESTROYED = "verification_vm_destroyed"
    OUTCOME_RETAINED = "verification_vm_retained"
    OUTCOME_NO_VM = "no_vm_to_finalize"

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      attempt:,
      lifecycle: nil,
      revocation: nil,
      failed_vm_retention_hours: DEFAULT_FAILED_VM_RETENTION_HOURS,
      clock: Time
    )
      @attempt = attempt
      @lifecycle = lifecycle
      @revocation = revocation || AppleVerification::Revocation::Enforce.new(
        attempt:, failed_vm_retention_hours:, clock:
      )
      @failed_vm_retention_hours = failed_vm_retention_hours
      @clock = clock
    end

    # Finalises an attempt. Successful attempts drive the real VM destroy
    # through the lifecycle boundary, then revoke credentials; failed
    # attempts persist the retention window and revoke credentials without
    # destroying the VM (which the sweep does after the deadline passes).
    # The success path refuses to record a `destroyed` audit event when no
    # real destroy happened: if the lifecycle is unavailable (host not
    # configured) or the lifecycle reports a +:noop+ (no live ledger entry
    # or no recorded vm_id), the call logs the skip, leaves the attempt's
    # terminal state untouched, and surfaces the gap to the caller instead
    # of asserting a destroy that did not occur. Mirrors the refusal
    # pattern in
    # {AppleVerification::Bundles::RetentionSweep#revoke_vm!}.
    def call
      return Result.new(outcome: OUTCOME_NO_VM, retained_until: nil, destroy_request_id: nil) unless @attempt.terminal?
      return finalized_result if @attempt.finalized_at?

      case @attempt.status
      when "succeeded"
        destroy_now!
        unless @last_destroy_result == :destroyed
          @revocation.revoke_credential!
          Rails.logger.warn(
            message: "apple_verification.complete_skipped",
            apple_verification_attempt_id: @attempt.id,
            reason: @last_destroy_skip_reason || "lifecycle_unavailable"
          )
          return Result.new(outcome: @attempt.status, retained_until: nil, destroy_request_id: nil)
        end
        @revocation.call
        mark_finalized!
        Result.new(outcome: OUTCOME_DESTROYED, retained_until: nil, destroy_request_id: @last_destroy_request_id)
      when "failed", "cancelled", "timed_out", "unavailable"
        @revocation.call
        mark_finalized!
        Result.new(outcome: OUTCOME_RETAINED, retained_until: @attempt.container_retained_until, destroy_request_id: nil)
      else
        Result.new(outcome: @attempt.status, retained_until: nil, destroy_request_id: nil)
      end
    end

    # Drives an early destroy of a retained failed VM through the lifecycle
    # boundary, then clears the retention deadline and records the audit
    # event via the revocation service. Used by the operator UI's "destroy
    # now" control and by the sweep when the deadline passes. Mirrors the
    # refusal pattern in {#call} and
    # {AppleVerification::Bundles::RetentionSweep#revoke_vm!}: a +:noop+
    # destroy (no live ledger entry or no recorded vm_id — the
    # partial-provisioning case) skips {#revoke_retained!} entirely, so no
    # `destroyed` audit event is recorded for a VM that was not destroyed
    # and +container_retained_until+ stays in place for the next sweep.
    def early_destroy_retained_vm
      lifecycle = resolve_lifecycle
      raise NoLifecycleError, "no Apple verification lifecycle available" unless lifecycle

      destroy_request_id = "early_destroy:#{@attempt.id}"
      destroy_result = begin
        lifecycle.destroy(attempt: @attempt, request_id: destroy_request_id)
      rescue StandardError => error
        Rails.logger.warn(
          message: "apple_verification.early_destroy_failed",
          apple_verification_attempt_id: @attempt.id,
          error_class: error.class.name,
          error: error.message
        )
        return Result.new(outcome: @attempt.status, retained_until: @attempt.container_retained_until, destroy_request_id: nil)
      end
      unless destroy_result == :destroyed
        Rails.logger.warn(
          message: "apple_verification.early_destroy_skipped",
          apple_verification_attempt_id: @attempt.id,
          reason: "destroy_noop"
        )
        return Result.new(outcome: @attempt.status, retained_until: @attempt.container_retained_until, destroy_request_id: nil)
      end

      @revocation.revoke_retained!
      Result.new(outcome: OUTCOME_DESTROYED, retained_until: nil, destroy_request_id: destroy_request_id)
    end

    NoLifecycleError = Class.new(StandardError)

    private

    attr_reader :attempt

    def destroy_now!
      lifecycle = resolve_lifecycle
      unless lifecycle
        @last_destroy_skip_reason = "lifecycle_unavailable"
        return
      end

      @last_destroy_request_id = "complete:#{@attempt.id}"
      @last_destroy_result = lifecycle.destroy(attempt: @attempt, request_id: @last_destroy_request_id)
      @last_destroy_skip_reason = "destroy_noop" if @last_destroy_result != :destroyed
    rescue StandardError => error
      @last_destroy_skip_reason = "destroy_failed"
      Rails.logger.warn(
        message: "apple_verification.complete_destroy_failed",
        apple_verification_attempt_id: @attempt.id,
        error_class: error.class.name,
        error: error.message
      )
    end

    def resolve_lifecycle
      return @lifecycle if @lifecycle

      @lifecycle = AppleVerification::Lifecycle.from_environment
    end

    def mark_finalized!
      @attempt.update!(finalized_at: current_time)
    end

    def finalized_result
      return Result.new(outcome: OUTCOME_DESTROYED, retained_until: nil, destroy_request_id: nil) if @attempt.succeeded?

      Result.new(outcome: OUTCOME_RETAINED, retained_until: @attempt.container_retained_until, destroy_request_id: nil)
    end

    def current_time
      return @clock.current if @clock.respond_to?(:current)
      return @clock.now if @clock.respond_to?(:now)

      @clock
    end
  end
end
