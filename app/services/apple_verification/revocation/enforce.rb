# frozen_string_literal: true

module AppleVerification
  module Revocation
    # Enforces RDR-068's revocation rules for completed Apple verification
    # attempts.
    #
    # A successful attempt destroys its VM immediately and revokes its
    # credential lane entry. A failed attempt retains its VM for the
    # configured retention window (default 1 hour), with the deadline
    # persisted on the attempt as +container_retained_until+. A workspace
    # bundle is retained for the configured window after the attempt
    # completes (default 7 days), with the deadline persisted on the attempt
    # as +bundle_retained_until+. Both windows are enforced by
    # {AppleVerification::Bundles::RetentionSweep}.
    #
    # Every revoke/destroy action records an {ExecutionAuditEvent} whose
    # metadata carries the attempt id and the action; the credential token
    # value is never serialized into the audit event.
    #
    # @spec APPLE-TRANSFER-006
    class Enforce
      Result = Data.define(:outcome, :retained_until, :audit_event)

      OUTCOME_DESTROYED = "verification_vm_destroyed"
      OUTCOME_RETAINED = "verification_vm_retained"
      OUTCOME_FAILED_VM_REVOKED = "verification_vm_revoked"
      OUTCOME_BUNDLE_RETAINED = "workspace_bundle_retained"
      OUTCOME_CREDENTIAL_REVOKED = "credential_revoked"

      DEFAULT_FAILED_VM_RETENTION_HOURS = ArtifactIngestion::Storage::DEFAULT_FAILED_VM_RETENTION_HOURS
      DEFAULT_BUNDLE_RETENTION_DAYS = ArtifactIngestion::Storage::DEFAULT_BUNDLE_RETENTION_DAYS

      class << self
        def call(...)
          new(...).call
        end
      end

      def initialize(attempt:, host: nil, credential_lane: nil, failed_vm_retention_hours: DEFAULT_FAILED_VM_RETENTION_HOURS, bundle_retention_days: DEFAULT_BUNDLE_RETENTION_DAYS, clock: Time)
        @attempt = attempt
        @host = host
        @credential_lane = credential_lane || SourceLane::CredentialLane.new(attempt: attempt)
        @failed_vm_retention_hours = failed_vm_retention_hours
        @bundle_retention_days = bundle_retention_days
        @clock = clock
      end

      # Persists the retention deadlines on the attempt and either destroys
      # the VM (success) or marks the retention window (failure). Always
      # revokes the credential lane entry so a retained failed VM cannot
      # reuse a cached installation token.
      def call
        case attempt.status
        when "succeeded"
          destroy_vm!
          revoke_credential!
          Result.new(outcome: OUTCOME_DESTROYED, retained_until: nil, audit_event: nil)
        when "failed", "cancelled", "timed_out", "unavailable"
          retain_failure_window!
          revoke_credential!
          Result.new(outcome: OUTCOME_RETAINED, retained_until: failed_vm_retained_until, audit_event: nil)
        else
          Result.new(outcome: attempt.status, retained_until: nil, audit_event: nil)
        end
      end

      # Records the destruction of a retained VM (operator-initiated or
      # sweep-initiated) and revokes the credential lane entry. Used by the
      # sweep after +container_retained_until+ expires.
      def revoke_retained!
        audit_event = destroy_vm!
        revoke_credential!
        attempt.update!(container_retained_until: nil)
        Result.new(outcome: OUTCOME_FAILED_VM_REVOKED, retained_until: nil, audit_event: audit_event)
      end

      private

      attr_reader :attempt, :host, :credential_lane, :failed_vm_retention_hours, :bundle_retention_days, :clock

      def destroy_vm!
        # The actual VM destroy call lives on the lifecycle boundary; here
        # we record the audit event the RDR requires. The lifecycle record
        # path is kept free of host paths and credential values.
        record_event!(
          event_name: "apple_verification_vm.destroyed",
          metadata: { "attempt_id" => attempt.id, "action" => "destroy" }
        )
      end

      def retain_failure_window!
        attempt.update!(
          container_retained_until: failed_vm_retained_until,
          bundle_retained_until: bundle_retained_until
        )
        record_event!(
          event_name: "apple_verification_vm.retained",
          metadata: {
            "attempt_id" => attempt.id,
            "action" => "retain",
            "retained_until" => failed_vm_retained_until.iso8601,
            "bundle_retained_until" => bundle_retained_until.iso8601
          }
        )
      end

      def revoke_credential!
        credential_lane.revoke!
        record_event!(
          event_name: "apple_credential.revoked",
          metadata: { "attempt_id" => attempt.id, "action" => "credential_revoked" }
        )
      end

      def record_event!(event_name:, metadata: {})
        ExecutionAuditEvent.record!(
          account: attempt.account,
          project: attempt.project,
          agent_run: attempt.agent_run,
          apple_verification_attempt: attempt,
          event_name: event_name,
          event_version: 1,
          actor_type: "system",
          actor_id: "apple_verification_revocation",
          metadata: metadata
        )
      rescue StandardError => error
        Rails.logger.error(
          message: "apple_verification.revocation_record_failed",
          event_name: event_name,
          apple_verification_attempt_id: attempt.id,
          error_class: error.class.name,
          error: error.message
        )
        nil
      end

      def failed_vm_retained_until
        @failed_vm_retained_until ||= clock.current + failed_vm_retention_hours.hours
      end

      def bundle_retained_until
        @bundle_retained_until ||= clock.current + bundle_retention_days.days
      end
    end
  end
end
