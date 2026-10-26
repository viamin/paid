# frozen_string_literal: true

module LayeredVerification
  module Evidence
    # Stores binary or textual evidence for a check result and returns the
    # key it was written under plus a link to it. When object storage is not
    # configured the evidence is not stored and the caller keeps the excerpt
    # inline in the check result's evidence summary.
    #
    # @spec LAYERED-VERIFY-022 @spec LAYERED-VERIFY-024
    class Store
      Result = Data.define(:key, :url) do
        def stored? = key.present?
      end

      def self.call(...)
        new(...).call
      end

      def initialize(key:, storage: nil)
        @key = key
        @storage = storage
      end

      def call(content)
        store = storage || ArtifactStorage.new
        return Result.new(key: nil, url: nil) unless store.configured?

        url = store.upload_io(io: StringIO.new(content.to_s), key:, content_type: "text/plain")
        Result.new(key:, url:)
      rescue ArtifactStorage::StorageError => e
        Rails.logger.warn(
          message: "layered_verification.evidence_store_failed",
          key:,
          error_class: e.class.name,
          error: e.message
        )
        Result.new(key: nil, url: nil)
      end

      private

      attr_reader :key, :storage
    end
  end
end
