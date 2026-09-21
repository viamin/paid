# frozen_string_literal: true

module AppleVerification
  module ArtifactIngestion
    # Ingests the structured artifacts produced by an Apple verification guest
    # (RDR-068 § Results and Artifacts).
    #
    # Each artifact descriptor is uploaded through the shared
    # {AppleVerification::ArtifactIngestion::Storage} under the attempt's
    # namespace, then returned as an `object_storage` lane reference ready to
    # embed in the output manifest. The ingester rejects descriptors that name
    # a host path, a kind outside the supported vocabulary, or an empty file,
    # and rejects attempts whose workflow profile has been revoked.
    #
    # @spec APPLE-TRANSFER-005
    class Ingest
      Result = Data.define(:references)

      UnsupportedKindError = Class.new(StandardError)
      EmptyArtifactError = Class.new(StandardError)
      HostPathError = Class.new(StandardError)
      RevokedProfileError = Class.new(StandardError)
      DisabledError = Class.new(StandardError)

      def self.call(...)
        new(...).call
      end

      def initialize(attempt:, descriptors:, storage: Storage.new)
        @attempt = attempt
        @descriptors = Array(descriptors)
        @storage = storage
      end

      def call
        ensure_feature_enabled!
        ensure_profile_not_revoked!
        ensure_no_host_paths!

        references = @descriptors.map { |descriptor| ingest_descriptor(descriptor) }
        Result.new(references: references)
      end

      private

      attr_reader :attempt, :descriptors, :storage

      def ensure_feature_enabled!
        return if FeatureFlags.enabled?(:apple_verification_workers, project: attempt.project)

        raise DisabledError, "apple_verification_workers is disabled for this project"
      end

      def ensure_profile_not_revoked!
        return unless attempt.apple_worker_profile&.revoked?

        raise RevokedProfileError, "attempt's worker profile has been revoked"
      end

      def ensure_no_host_paths!
        @descriptors.each do |descriptor|
          descriptor_hash = descriptor.is_a?(Hash) ? descriptor.deep_stringify_keys : {}
          raise HostPathError, "artifact descriptor must not include host_path" if descriptor_hash.key?("host_path")
          raise HostPathError, "artifact descriptor must not include host_mount" if descriptor_hash.key?("host_mount")
        end
      end

      def ingest_descriptor(descriptor)
        descriptor_hash = descriptor.is_a?(Hash) ? descriptor.deep_stringify_keys : {}
        kind = descriptor_hash["kind"].to_s
        name = descriptor_hash["name"].to_s
        bytes = descriptor_hash["bytes"]
        file_path = descriptor_hash["file_path"].presence
        content_type = descriptor_hash["content_type"].presence
        digest = descriptor_hash["digest"].to_s.presence

        validate_kind!(kind)
        validate_name!(name)
        ensure_artifact_payload!(descriptor_hash, bytes:, file_path:)

        body = bytes || File.binread(file_path)
        raise EmptyArtifactError, "artifact #{name} for #{kind} is empty" if body.to_s.bytesize.zero?

        key = storage.upload_bytes(
          bytes: body,
          account_id: account_id,
          project_id: project_id,
          attempt_id: attempt.id,
          kind: kind,
          name: name,
          content_type: content_type
        )

        build_reference(kind:, name:, key:, digest:, bytesize: body.bytesize)
      end

      def validate_kind!(kind)
        return if Storage::SUPPORTED_KINDS.include?(kind)

        raise UnsupportedKindError, "unsupported artifact kind: #{kind.inspect}"
      end

      def validate_name!(name)
        raise EmptyArtifactError, "artifact name is required" if name.blank?
        raise HostPathError, "artifact name must not be a host path" if name.include?("/") || name.start_with?("..")
      end

      def ensure_artifact_payload!(descriptor, bytes:, file_path:)
        return if bytes.is_a?(String)
        return if file_path.is_a?(String) && File.exist?(file_path)

        raise EmptyArtifactError, "artifact #{descriptor['name']} for #{descriptor['kind']} has no payload"
      end

      def build_reference(kind:, name:, key:, digest:, bytesize:)
        locator = { "key" => key, "url" => storage.signed_url(key) }
        locator["sha256"] = digest if digest.present?
        {
          "lane" => "object_storage",
          "kind" => kind,
          "name" => name,
          "content_type" => Storage.content_type_for(kind),
          "bytesize" => bytesize,
          "locator" => locator
        }
      end

      def account_id
        attempt.account_id
      end

      def project_id
        attempt.project_id
      end
    end
  end
end
