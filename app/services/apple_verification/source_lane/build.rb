# frozen_string_literal: true

module AppleVerification
  module SourceLane
    # Composes the four input manifest lane entries for an Apple verification
    # attempt (RDR-068 § Source and Credential Transfer).
    #
    # A committed attempt produces a `git` lane referencing the exact commit
    # identity, a `credentials` lane referencing a short-lived GitHub App
    # installation, and empty `object_storage` / `control_plane_api` lanes.
    # An uncommitted attempt produces an `object_storage` lane referencing a
    # content-addressed workspace bundle, an empty `credentials` lane, and the
    # same `git` lane shape with no `commit_sha`. For uncommitted attempts
    # the bundle's content digest is `attempt.source_digest` — the attempt is
    # expected to have been created with the digest returned by
    # {AppleVerification::SourceLane::BundleBuilder#call} so the guest's
    # digest verification ({docs/rdrs/RDR-068-apple-platform-verification-workers.md}
    # § Uncommitted source) checks the bytes that were actually shipped, not
    # a stale or unrelated value. The builder rejects host paths, bind
    # mounts, and writable cross-project caches in either branch, and refuses
    # to build any lane when the originating paid-agent container has a
    # write-host mount bound into its workspace (the caller-supplied
    # `host_mount_check` inspects the originating container; passing it is
    # required because the executor is the only party that can resolve the
    # container's bind/mount table).
    #
    # @spec APPLE-TRANSFER-001
    # @spec APPLE-TRANSFER-003
    class Build
      Result = Data.define(:git, :credentials, :object_storage, :control_plane_api)

      IncompatibleSourceError = Class.new(StandardError)
      HostMountPresentError = Class.new(StandardError)
      BundlesNotSupportedError = Class.new(StandardError)

      def self.call(...)
        new(...).call
      end

      def initialize(attempt:, host_mount_check:)
        @attempt = attempt
        @host_mount_check = host_mount_check
      end

      def call
        ensure_feature_enabled!
        ensure_no_host_mounts!

        if committed?
          Result.new(
            git: [ git_lane_for_commit ],
            credentials: [ credential_lane_entry ],
            object_storage: [],
            control_plane_api: []
          )
        else
          Result.new(
            git: [ git_lane_for_bundle ],
            credentials: [],
            object_storage: [ object_storage_lane_entry ],
            control_plane_api: []
          )
        end
      end

      private

      attr_reader :attempt, :host_mount_check

      def committed?
        attempt.commit_sha.present?
      end

      def ensure_feature_enabled!
        return if FeatureFlags.enabled?(:apple_verification_workers, project: project)

        raise AppleVerification::ExecuteGuestJob::FeatureDisabledError, "apple_verification_workers is disabled for this project"
      end

      def ensure_no_host_mounts!
        agent_run = attempt.agent_run
        return unless agent_run

        # `host_mount_check` is required: APPLE-TRANSFER-003 makes the
        # write-host-mount guard a hard requirement and the executor that
        # drives the source lane owns the authoritative container/mount
        # inspection. Defaulting to a permissive lambda would silently disable
        # the guard for callers that forget to wire it up, which is the exact
        # failure mode RDR-068 was written to prevent.
        raise HostMountPresentError, "apple verification rejects paid-agent containers with a write host mount" if host_mount_check.call(agent_run)
      end

      def project
        attempt.project
      end

      def git_lane_for_commit
        {
          "lane" => "git",
          "kind" => "repository_checkout",
          "locator" => {
            "repo_full_name" => project.full_name,
            "commit_sha" => attempt.commit_sha
          }.compact
        }
      end

      def git_lane_for_bundle
        {
          "lane" => "git",
          "kind" => "workspace_bundle",
          "locator" => {
            "repo_full_name" => project.full_name,
            "bundle_digest" => attempt.source_digest
          }.compact
        }
      end

      def credential_lane_entry
        result = SourceLane::CredentialLane.call(attempt: attempt)
        SourceLane::CredentialLane.lane_entry(result)
      end

      def object_storage_lane_entry
        raise BundlesNotSupportedError, "attempt has no bundle digest" if attempt.source_digest.blank?

        {
          "lane" => "object_storage",
          "kind" => "workspace_bundle",
          "locator" => {
            "digest" => attempt.source_digest,
            "key" => bundle_key,
            "url" => bundle_url
          }.compact
        }
      end

      def bundle_key
        AppleVerification::ArtifactIngestion::Storage.bundle_key(
          account_id: project.account_id,
          project_id: project_id,
          attempt_id: attempt.id
        )
      end

      def bundle_url
        AppleVerification::ArtifactIngestion::Storage.bundle_url(
          account_id: project.account_id, project_id: project_id, attempt_id: attempt.id, digest: attempt.source_digest
        )
      end

      def project_id
        project.id
      end
    end
  end
end
