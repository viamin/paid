# frozen_string_literal: true

module AppleVerification
  module ArtifactIngestion
    # Per-attempt object storage namespace for Apple verification artifacts
    # (RDR-068 § Results and Artifacts). Keys are namespaced under
    # `apple-verification/{account_id}/{project_id}/{attempt_id}/{kind}/...`
    # so they cannot collide with the screenshot, agent run, or knowledge
    # namespaces; an artifact from another tenant never lands under the same
    # prefix and durable consumers can re-sign keys only within the run's own
    # tenant namespace.
    #
    # The shared {ArtifactStorage} module owns S3 client construction; this
    # class only knows the apple-verification key layout, the supported
    # artifact kinds, and the namespace prefix the durable output manifest
    # uses to scope re-signing.
    # @spec ARTIFACT-STORAGE-003
    # @spec APPLE-TRANSFER-005
    class Storage
      SUPPORTED_KINDS = %w[xcresult build_log screenshot diagnostics manifest].freeze
      DEFAULT_BINARY_RETENTION_DAYS = 30
      DEFAULT_BUNDLE_RETENTION_DAYS = 7
      DEFAULT_FAILED_VM_RETENTION_HOURS = 1
      BUNDLE_CONTENT_TYPE = "application/x-tar+gzip"
      XCRESULT_CONTENT_TYPE = "application/x-xcresult"
      LOG_CONTENT_TYPE = "text/plain"
      SCREENSHOT_CONTENT_TYPE = "image/png"
      DIAGNOSTICS_CONTENT_TYPE = "application/json"

      # The key prefix every apple-verification artifact key starts with. The
      # durable output manifest's trusted lane
      # ({AppleVerification::ResultManifest::Build}) only honors persisted
      # locator keys under this prefix for the attempt's own account, so a
      # key planted under another tenant's namespace can never be re-signed
      # into a working presigned URL.
      # @spec APPLE-TRANSFER-005
      # @return [String]
      def self.namespace_prefix(account_id:, project_id:, attempt_id:)
        "apple-verification/#{account_id}/#{project_id}/#{attempt_id}/"
      end

      def self.bundle_key(account_id:, project_id:, attempt_id:)
        "#{namespace_prefix(account_id:, project_id:, attempt_id:)}source.tar"
      end

      def self.artifact_key(account_id:, project_id:, attempt_id:, kind:, name:)
        raise ArgumentError, "unsupported artifact kind: #{kind.inspect}" unless SUPPORTED_KINDS.include?(kind.to_s)

        "#{namespace_prefix(account_id:, project_id:, attempt_id:)}#{kind}/#{name}"
      end

      def self.bundle_url(account_id:, project_id:, attempt_id:, digest:)
        bucket, region = storage_config
        return nil unless bucket && region && digest.present?

        "https://#{bucket}.s3.#{region}.amazonaws.com/#{bundle_key(account_id:, project_id:, attempt_id:)}?digest=#{digest}"
      end

      def self.content_type_for(kind)
        case kind.to_s
        when "xcresult" then XCRESULT_CONTENT_TYPE
        when "build_log" then LOG_CONTENT_TYPE
        when "screenshot" then SCREENSHOT_CONTENT_TYPE
        when "diagnostics" then DIAGNOSTICS_CONTENT_TYPE
        when "manifest" then "application/json"
        else "application/octet-stream"
        end
      end

      def self.storage_config
        return [ nil, nil ] unless ArtifactStorage.configured?

        [ ArtifactStorage.configured_bucket, ArtifactStorage.configured_region ]
      end

      def initialize(artifact_storage: ArtifactStorage.new)
        @artifact_storage = artifact_storage
      end

      attr_reader :artifact_storage

      def upload(file_path:, account_id:, project_id:, attempt_id:, kind:, name:, content_type: nil)
        key = self.class.artifact_key(account_id:, project_id:, attempt_id:, kind:, name:)
        resolved_content_type = content_type || self.class.content_type_for(kind)
        @artifact_storage.upload(file_path:, key:, content_type: resolved_content_type)
        key
      end

      def upload_bytes(bytes:, account_id:, project_id:, attempt_id:, kind:, name:, content_type: nil)
        key = self.class.artifact_key(account_id:, project_id:, attempt_id:, kind:, name:)
        resolved_content_type = content_type || self.class.content_type_for(kind)
        @artifact_storage.client.put_object(
          bucket: @artifact_storage.bucket,
          key: key,
          body: bytes,
          content_type: resolved_content_type
        )
        key
      rescue Aws::S3::Errors::ServiceError => e
        raise ArtifactStorage::StorageError, "apple artifact upload failed: #{e.message}"
      end

      def signed_url(key)
        @artifact_storage.signed_url(key)
      end

      def delete_key(key)
        @artifact_storage.delete(key)
      end

      def delete_prefix(prefix)
        @artifact_storage.delete_prefix(prefix)
      end
    end
  end
end
