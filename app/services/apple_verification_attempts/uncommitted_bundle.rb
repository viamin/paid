# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-008
  # Builds the content-addressed workspace bundle for an uncommitted Apple
  # verification attempt. The bundle is the boundary that lets a paid-agent
  # container ship code to a macOS guest without a host bind mount: the
  # bundle excludes credentials, caches, derived data, build outputs, and
  # forbidden binaries; runs the existing secret-scan safety check; records
  # a manifest and content digest; and transfers through Paid's artifact
  # lane. The bundle is deleted by the retention sweep after the attempt
  # and retry window elapse; the digest, safe manifest, and provenance stay
  # so the attempt stays attributable.
  class UncommittedBundle
    Result = Data.define(:digest, :bytesize, :manifest, :bundle_key, :bundle_url)

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      attempt:,
      workspace_root:,
      builder: AppleVerification::SourceLane::BundleBuilder,
      storage: AppleVerification::ArtifactIngestion::Storage.new,
      retention_days: AppleVerification::Revocation::Enforce::DEFAULT_BUNDLE_RETENTION_DAYS
    )
      @attempt = attempt
      @workspace_root = workspace_root
      @builder = builder
      @storage = storage
      @retention_days = retention_days
    end

    def call
      raise ArgumentError, "attempt is not an uncommitted bundle attempt" if @attempt.commit_sha.present?

      output_path = bundle_output_path
      manifest_path = "#{output_path}.manifest.json"

      builder_result = builder_instance.call(workspace_root: @workspace_root, output_path:, manifest_path:)

      Result.new(
        digest: builder_result.digest,
        bytesize: builder_result.bytesize,
        manifest: builder_result.manifest,
        bundle_key: AppleVerification::ArtifactIngestion::Storage.bundle_key(
          account_id: @attempt.account_id,
          project_id: @attempt.project_id,
          attempt_id: @attempt.id
        ),
        bundle_url: AppleVerification::ArtifactIngestion::Storage.bundle_url(
          account_id: @attempt.account_id,
          project_id: @attempt.project_id,
          attempt_id: @attempt.id,
          digest: builder_result.digest
        )
      )
    end

    private

    attr_reader :attempt, :workspace_root, :retention_days

    def builder_instance
      # BundleBuilder exposes a Class-level `.call(workspace_root:, output_path:,
      # manifest_path:)` that builds the instance itself, so a Class builder is
      # already the callable the call site expects. Non-Class callables (lambdas,
      # procs, service objects) are returned as-is.
      @builder
    end

    def bundle_output_path
      directory = storage_output_directory
      FileUtils.mkdir_p(directory)
      File.join(directory, "source.tar")
    end

    def storage_output_directory
      # Bundles live under the project's tmp dir so a snapshot of the
      # workspace can be assembled alongside other transient attempt state
      # and cleaned up with the rest of the project's tmp tree. Callers
      # may override via +storage: a configured AppleVerification::
      # ArtifactIngestion::Storage instance.
      return @storage.output_directory if @storage.respond_to?(:output_directory)

      File.join(Rails.root.to_s, "tmp", "apple_verification_attempts", @attempt.id.to_s)
    end

    def storage
      @storage.is_a?(Class) ? @storage.new : @storage
    end
  end
end
