# frozen_string_literal: true

module AppleVerification
  module Bundles
    # Sweeps expired workspace bundles and revoked Apple verification VMs
    # (RDR-068 § Revocation and deletion rules).
    #
    # For each attempt whose +bundle_retained_until+ has passed and whose
    # bundle is still present in object storage, the sweep deletes every key
    # under the attempt's namespace and clears the attempt's retention
    # deadline so the durable manifest, audit events, and ledger entries
    # remain attributable while the binary artifact is gone. For each
    # attempt whose +container_retained_until+ has passed and whose VM is
    # still active, the sweep invokes {Revocation::Enforce#revoke_retained!}
    # to destroy the VM and revoke the credential lane entry.
    #
    # The sweep is idempotent: an attempt whose retention deadline is in
    # the future is skipped, and an attempt whose retention deadline is
    # already cleared is also skipped.
    #
    # @spec APPLE-TRANSFER-006
    class RetentionSweep
      Result = Data.define(:bundles_deleted, :vms_revoked, :attempts_scanned)

      DEFAULT_BATCH_SIZE = 100

      def self.call(...)
        new(...).call
      end

      def initialize(storage: AppleVerification::ArtifactIngestion::Storage.new, revocation: nil, clock: Time, batch_size: DEFAULT_BATCH_SIZE)
        @storage = storage
        @revocation = revocation
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

      def expired_bundles
        AppleVerificationAttempt.where("bundle_retained_until IS NOT NULL AND bundle_retained_until <= ?", clock.current)
      end

      def expired_vms
        AppleVerificationAttempt
          .where(status: AppleVerificationAttempt::TERMINAL_STATES - %w[succeeded])
          .where("container_retained_until IS NOT NULL AND container_retained_until <= ?", clock.current)
      end

      def delete_bundle!(attempt)
        prefix = AppleVerification::ArtifactIngestion::Storage.namespace_prefix(
          account_id: attempt.account_id,
          project_id: attempt.project_id,
          attempt_id: attempt.id
        )
        storage.delete_prefix(prefix)
        attempt.update!(bundle_retained_until: nil)
        true
      rescue Aws::S3::Errors::ServiceError => error
        Rails.logger.warn(
          message: "apple_verification.bundle_retention_sweep_failed",
          apple_verification_attempt_id: attempt.id,
          error_class: error.class.name,
          error: error.message
        )
        false
      end

      def revoke_vm!(attempt)
        revocation_service_for(attempt).revoke_retained!
        attempt.update!(container_retained_until: nil)
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
