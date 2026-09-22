# frozen_string_literal: true

module AppleVerification
  module Bundles
    # Sweeps expired workspace bundles and revoked Apple verification VMs
    # (RDR-068 § Revocation and deletion rules).
    #
    # For each attempt whose +bundle_retained_until+ has passed and whose
    # bundle is still present in object storage, the sweep deletes the
    # attempt's source bundle key and clears the attempt's retention
    # deadline so the durable manifest, audit events, and ledger entries
    # remain attributable while the binary artifact is gone. Only the
    # bundle key is deleted: the artifact binaries (`.xcresult`, build logs,
    # screenshots, diagnostics) uploaded by
    # {AppleVerification::ArtifactIngestion::Ingest} live under sibling keys
    # in the same namespace and follow their own retention window. For each
    # attempt whose +container_retained_until+ has passed, the sweep first
    # drives the real VM destruction through the {AppleVerification::Lifecycle}
    # boundary (a Tart +host.destroy+ over the same authenticated channel the
    # lifecycle used to provision) so the audit event recorded downstream by
    # {AppleVerification::Revocation::Enforce#revoke_retained!} reflects a
    # real destroy rather than a no-op. When no lifecycle is available —
    # either injected via +lifecycle:+ or discoverable from the
    # +APPLE_VERIFICATION_HOST_URL+ / +APPLE_VERIFICATION_HOST_TOKEN+
    # environment variables — the sweep refuses to record a `destroyed`
    # audit event it cannot back up and leaves +container_retained_until+
    # in place so a later sweep run, once the macOS worker is configured,
    # picks the attempt up. The same refusal applies when the lifecycle
    # reports the destroy as a no-op: {AppleVerification::Lifecycle#destroy}
    # returns +:noop+ for attempts that have no live ledger entry or no
    # recorded +vm_id+ (e.g. failures that never reached provisioning), and
    # the sweep leaves the deadline in place and records no audit event
    # rather than asserting a destroy that did not happen. The sweep is
    # idempotent: an attempt whose retention deadline is in the future is
    # skipped, an attempt whose retention deadline is already cleared is
    # also skipped, and the underlying {ArtifactStorage#delete} call is a
    # no-op when the key is missing.
    #
    # @spec APPLE-TRANSFER-006
    class RetentionSweep
      Result = Data.define(:bundles_deleted, :vms_revoked, :attempts_scanned)

      DEFAULT_BATCH_SIZE = 100

      def self.call(...)
        new(...).call
      end

      def initialize(storage: AppleVerification::ArtifactIngestion::Storage.new, revocation: nil, lifecycle: nil, clock: Time, batch_size: DEFAULT_BATCH_SIZE)
        @storage = storage
        @revocation = revocation
        @lifecycle = lifecycle || default_lifecycle
        @clock = clock
        @batch_size = batch_size
      end

      def call
        bundles_deleted = 0
        vms_revoked = 0
        attempts_scanned = 0

        expired_bundles.find_each(batch_size: @batch_size) do |attempt|
          attempts_scanned += 1
          bundles_deleted += 1 if delete_bundle!(attempt)
        end

        expired_vms.find_each(batch_size: @batch_size) do |attempt|
          attempts_scanned += 1
          vms_revoked += 1 if revoke_vm!(attempt)
        end

        Result.new(bundles_deleted:, vms_revoked:, attempts_scanned:)
      end

      private

      attr_reader :storage, :clock, :batch_size

      def revocation_service_for(attempt)
        @revocation || AppleVerification::Revocation::Enforce.new(attempt: attempt)
      end

      def lifecycle_for(_attempt)
        @lifecycle
      end

      def default_lifecycle
        AppleVerification::Lifecycle.from_environment
      end

      def expired_bundles
        AppleVerificationAttempt.where("bundle_retained_until IS NOT NULL AND bundle_retained_until <= ?", clock.current)
      end

      def expired_vms
        AppleVerificationAttempt
          .where(status: AppleVerificationAttempt::TERMINAL_STATES - %w[succeeded])
          .where("container_retained_until IS NOT NULL AND container_retained_until <= ?", clock.current)
      end

      def delete_bundle!(attempt)
        key = AppleVerification::ArtifactIngestion::Storage.bundle_key(
          account_id: attempt.account_id,
          project_id: attempt.project_id,
          attempt_id: attempt.id
        )
        storage.delete_key(key)
        attempt.update!(bundle_retained_until: nil)
        true
      rescue ArtifactStorage::StorageError => error
        Rails.logger.warn(
          message: "apple_verification.bundle_retention_sweep_failed",
          apple_verification_attempt_id: attempt.id,
          error_class: error.class.name,
          error: error.message
        )
        false
      end

      def revoke_vm!(attempt)
        # Drive the real host destroy first so the audit event recorded by
        # {AppleVerification::Revocation::Enforce#revoke_retained!} reflects
        # an actual destroy rather than a no-op. The macOS worker must be
        # configured (or a lifecycle must be injected) for the sweep to
        # drive a real destroy; if neither is available the sweep refuses
        # to record an `apple_verification_vm.destroyed` audit event for a
        # VM it did not actually destroy and leaves the deadline in place
        # so the next sweep run (after the worker is configured) picks the
        # attempt up. A destroy that reports +:noop+ (no live ledger entry
        # or no recorded +vm_id+) gets the same treatment: no audit event,
        # deadline kept, so a later run retries once the destroy can be
        # backed by a real host action.
        lifecycle = lifecycle_for(attempt)
        unless lifecycle
          Rails.logger.warn(
            message: "apple_verification.vm_retention_sweep_skipped",
            apple_verification_attempt_id: attempt.id,
            reason: "lifecycle_unavailable"
          )
          return false
        end

        destroy_request_id = "retention_sweep:destroy:#{attempt.id}"
        destroy_result = lifecycle.destroy(attempt: attempt, request_id: destroy_request_id)
        unless destroy_result == :destroyed
          Rails.logger.warn(
            message: "apple_verification.vm_retention_sweep_skipped",
            apple_verification_attempt_id: attempt.id,
            reason: "destroy_noop"
          )
          return false
        end

        revocation_service_for(attempt).revoke_retained!
        true
      rescue StandardError => error
        Rails.logger.warn(
          message: "apple_verification.vm_retention_sweep_failed",
          apple_verification_attempt_id: attempt.id,
          error_class: error.class.name,
          error: error.message
        )
        false
      end
    end
  end
end
