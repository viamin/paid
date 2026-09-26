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

      # Terminal attempt statuses whose VM and credentials this service may
      # revoke. Any status outside this set is left untouched.
      REVOCABLE_OUTCOMES = %w[succeeded failed cancelled timed_out unavailable].freeze

      DEFAULT_FAILED_VM_RETENTION_HOURS = ArtifactIngestion::Storage::DEFAULT_FAILED_VM_RETENTION_HOURS
      DEFAULT_BUNDLE_RETENTION_DAYS = ArtifactIngestion::Storage::DEFAULT_BUNDLE_RETENTION_DAYS

      class << self
        def call(...)
          new(...).call
        end
      end

      def initialize(attempt:, outcome: attempt.status, credential_lane: nil, lifecycle: AppleVerification::Lifecycle.from_environment, failed_vm_retention_hours: DEFAULT_FAILED_VM_RETENTION_HOURS, bundle_retention_days: DEFAULT_BUNDLE_RETENTION_DAYS, clock: Time, vm_destroy_result: nil)
        @attempt = attempt
        @outcome = outcome
        @credential_lane = credential_lane || SourceLane::CredentialLane.new(attempt: attempt)
        @lifecycle = lifecycle
        @failed_vm_retention_hours = failed_vm_retention_hours
        @bundle_retention_days = bundle_retention_days
        @clock = clock
        @vm_destroy_result = vm_destroy_result
      end

      # Persists the retention deadlines on the attempt and either records the
      # VM destruction audit event (when the caller reports a real destroy via
      # +vm_destroy_result == :destroyed+) or marks the VM retention window
      # (any other result). The actual VM destruction is the caller's
      # responsibility — the immediate-success path and host-safety
      # termination drive the lifecycle boundary before revocation and report
      # the destroy outcome through +vm_destroy_result+, so the `destroyed`
      # audit event is recorded only for a destroy that actually happened;
      # any other result (missing lifecycle, destroy error, or no-op) falls
      # back to the failure retention window so
      # {AppleVerification::Bundles::RetentionSweep} retries the destroy. The
      # sweep drives destruction via the lifecycle boundary before calling
      # {#revoke_retained!}. Always revokes the credential lane entry so a
      # retained failed VM cannot reuse a cached installation token.
      def call
        return Result.new(outcome: outcome, retained_until: nil, audit_event: nil) unless outcome.in?(REVOCABLE_OUTCOMES)

        vm_destroy_result == :destroyed ? finalize_destroyed_vm : finalize_retained_vm
      end

      # Records the audit event for destruction of a retained VM
      # (operator-initiated or sweep-initiated) and revokes the credential
      # lane entry. Used by the sweep after +container_retained_until+
      # expires; the sweep must destroy the VM via the lifecycle boundary
      # before calling here so this method's audit event reflects a real
      # destroy, not a no-op.
      def revoke_retained!
        audit_event = record_vm_destroyed!
        revoke_credential!
        attempt.update!(container_retained_until: nil)
        Result.new(outcome: OUTCOME_FAILED_VM_REVOKED, retained_until: nil, audit_event: audit_event)
      end

      private

      attr_reader :attempt, :outcome, :credential_lane, :lifecycle, :failed_vm_retention_hours, :bundle_retention_days, :clock, :vm_destroy_result

      def finalize_destroyed_vm
        record_vm_destroyed!
        revoke_credential!
        persist_bundle_retained_until!
        Result.new(outcome: OUTCOME_DESTROYED, retained_until: nil, audit_event: nil)
      end

      def finalize_retained_vm
        disable_retained_vm_network!
        retain_failure_window!
        revoke_credential!
        Result.new(outcome: OUTCOME_RETAINED, retained_until: failed_vm_retained_until, audit_event: nil)
      end

      # A stopped Tart guest has no active Softnet connection. Keep its ledger
      # entry live for the retention sweep, which later performs destruction.
      # A missing entry is safe: {Lifecycle#stop} returns +:noop+ only when no
      # VM exists to retain.
      def disable_retained_vm_network!
        lifecycle&.stop(attempt: attempt, request_id: "revocation:stop:#{attempt.id}")
      end

      def record_vm_destroyed!
        # The actual VM destroy call lives on the lifecycle boundary; this
        # method records the audit event the RDR requires. The lifecycle
        # record path is kept free of host paths and credential values.
        # Callers (the executor for immediate-success, the sweep for
        # retention-expired) must drive the real destroy via the lifecycle
        # boundary before invoking this method.
        record_event!(
          event_name: "apple_verification_vm.destroyed",
          metadata: { "attempt_id" => attempt.id, "action" => "destroy" }
        )
      end

      # Committed attempts have no workspace bundle in object storage, so the
      # retention sweep has nothing to delete; only uncommitted attempts ship a
      # bundle under `apple-verification/.../source.tar` that must be retained
      # for the configured window. The committed/uncommitted distinction lives
      # on `commit_sha` (per {AppleVerification::SourceLane::Build#committed?}),
      # mirroring the success-path guard in {#persist_bundle_retained_until!}.
      def retain_failure_window!
        bundle_deadline = bundle_retained_for_attempt
        attempt.update!(
          container_retained_until: failed_vm_retained_until,
          bundle_retained_until: bundle_deadline
        )
        record_event!(
          event_name: "apple_verification_vm.retained",
          metadata: retain_failure_window_metadata(bundle_deadline)
        )
      end

      def revoke_credential!
        # Uncommitted attempts never have a credentials lane entry or a
        # minted installation token, so {CredentialLane#revoke!} early-returns
        # and no remote revoke happens. Recording the audit event for an
        # attempt with no `commit_sha` would assert a revocation that did
        # not occur, polluting the append-only audit trail; mirror the
        # `CredentialLane#revoke!` commit_sha-present? guard here so the
        # audit event only fires when a revocation actually took place.
        return unless attempt.commit_sha.present?

        credential_lane.revoke!
        record_event!(
          event_name: "apple_credential.revoked",
          metadata: { "attempt_id" => attempt.id, "action" => "credential_revoked" }
        )
      end

      # Committed attempts have no workspace bundle in object storage, so the
      # retention sweep has nothing to delete; uncommitted attempts ship a
      # bundle under `apple-verification/.../source.tar` that must be retained
      # for the configured window so the sweep can pick it up and only the
      # bundle key is deleted, not the attempt's artifact namespace. The
      # committed/uncommitted distinction lives on `commit_sha` (per
      # {AppleVerification::SourceLane::Build#committed?}). `source_digest`
      # is set on every attempt at creation time and means different things
      # in each branch: for uncommitted attempts it is the workspace
      # bundle's content digest returned by
      # {AppleVerification::SourceLane::BundleBuilder#call} (so the guest can
      # verify the bytes it actually extracts); for committed attempts the
      # caller records whatever content digest the execution binding is
      # bound to — the bundle sweep uses `commit_sha` presence, not the
      # digest value, to decide whether a bundle is in flight.
      def persist_bundle_retained_until!
        return if attempt.commit_sha.present?

        attempt.update!(bundle_retained_until: bundle_retained_until)
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

      def bundle_retained_for_attempt
        return nil if attempt.commit_sha.present?

        bundle_retained_until
      end

      def retain_failure_window_metadata(bundle_deadline)
        metadata = {
          "attempt_id" => attempt.id,
          "action" => "retain",
          "retained_until" => failed_vm_retained_until.iso8601
        }
        metadata["bundle_retained_until"] = bundle_deadline.iso8601 if bundle_deadline
        metadata
      end
    end
  end
end
