# frozen_string_literal: true

require "digest"

module AppleVerification
  module ArtifactIngestion
    # Ingests the structured artifacts produced by an Apple verification guest
    # (RDR-068 § Results and Artifacts).
    #
    # Descriptors are untrusted guest input: each one carries its payload
    # inline (`bytes`), and the ingester uploads those bytes through the
    # shared {AppleVerification::ArtifactIngestion::Storage} under the
    # attempt's namespace before returning an `object_storage` lane reference
    # ready to embed in the output manifest. Artifact bytes are never read
    # from the Rails host filesystem. The ingester rejects descriptors that
    # name a host path (`host_path`, `host_mount`, or `file_path`), a kind
    # outside the supported vocabulary, or an empty payload; rejects a
    # guest-reported digest that disagrees with the uploaded bytes (the
    # locator digest is always computed server-side); and rejects attempts
    # whose workflow profile has been revoked.
    #
    # @spec APPLE-TRANSFER-005
    class Ingest
      Result = Data.define(:references)

      FORBIDDEN_DESCRIPTOR_KEYS = %w[host_path host_mount file_path].freeze

      UnsupportedKindError = Class.new(StandardError)
      EmptyArtifactError = Class.new(StandardError)
      HostPathError = Class.new(StandardError)
      DigestMismatchError = Class.new(StandardError)
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
          FORBIDDEN_DESCRIPTOR_KEYS.each do |key|
            raise HostPathError, "artifact descriptor must not include #{key}" if descriptor_hash.key?(key)
          end
        end
      end

      def ingest_descriptor(descriptor)
        descriptor_hash = descriptor.is_a?(Hash) ? descriptor.deep_stringify_keys : {}
        kind = descriptor_hash["kind"].to_s
        name = descriptor_hash["name"].to_s
        bytes = descriptor_hash["bytes"]
        content_type = descriptor_hash["content_type"].presence
        reported_digest = descriptor_hash["digest"].to_s.presence

        validate_kind!(kind)
        validate_name!(name)
        ensure_artifact_payload!(descriptor_hash, bytes:)

        raise EmptyArtifactError, "artifact #{name} for #{kind} is empty" if bytes.bytesize.zero?

        computed_digest = Digest::SHA256.hexdigest(bytes)
        verify_reported_digest!(reported_digest, computed: computed_digest, name: name, kind: kind)

        key = storage.upload_bytes(
          bytes: bytes,
          account_id: account_id,
          project_id: project_id,
          attempt_id: attempt.id,
          kind: kind,
          name: name,
          content_type: content_type
        )

        build_reference(kind:, key:, sha256: "sha256:#{computed_digest}")
      end

      def validate_kind!(kind)
        return if Storage::SUPPORTED_KINDS.include?(kind)

        raise UnsupportedKindError, "unsupported artifact kind: #{kind.inspect}"
      end

      def validate_name!(name)
        raise EmptyArtifactError, "artifact name is required" if name.blank?
        raise HostPathError, "artifact name must not be a host path" if name.include?("/") || name.start_with?("..")
      end

      def ensure_artifact_payload!(descriptor, bytes:)
        return if bytes.is_a?(String)

        raise EmptyArtifactError, "artifact #{descriptor['name']} for #{descriptor['kind']} has no payload"
      end

      def verify_reported_digest!(reported, computed:, name:, kind:)
        return if reported.blank?
        # The guest may report the algorithm prefix in either case
        # (`sha256:` / `SHA256:`); strip it case-insensitively and compare
        # the hex digits lowercased so a valid mixed-case digest is
        # accepted while any real mismatch still fails.
        return if reported.sub(/\Asha256:/i, "").downcase == computed

        raise DigestMismatchError, "artifact #{name} for #{kind} reported digest #{reported} but bytes hash to sha256:#{computed}"
      end

      def build_reference(kind:, key:, sha256:)
        locator = { "key" => key, "url" => storage.signed_url(key), "sha256" => sha256 }
        { "lane" => "object_storage", "kind" => kind, "locator" => locator }
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
