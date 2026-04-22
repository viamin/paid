# frozen_string_literal: true

module Knowledge
  module Qdrant
    class CollectionManager
      PAYLOAD_INDEX_SCHEMAS = {
        "account_id" => "integer",
        "project_version_id" => "integer",
        "artifact_type" => "keyword",
        "status" => "keyword"
      }.freeze

      attr_reader :project, :client

      def initialize(project:, client: Paid.qdrant_client)
        @project = project
        @client = client
      end

      def self.ensure_collection!(project, client: Paid.qdrant_client)
        new(project: project, client: client).ensure_collection!
      end

      def self.drop_collection!(project, client: Paid.qdrant_client)
        new(project: project, client: client).drop_collection!
      end

      def self.rebuild_schema!(project, client: Paid.qdrant_client)
        new(project: project, client: client).rebuild_schema!
      end

      def ensure_collection!
        return if collection_exists?

        if legacy_collection_exists?
          alias_legacy_collection!
          return
        end

        create_collection!
        create_payload_indexes!
      end

      def drop_collection!
        return unless collection_exists?

        client.collections.delete(collection_name: collection_name)
      end

      # Drops and recreates the Qdrant collection structure (schema + indexes).
      # Does NOT re-upsert points — embeddings must be recomputed separately
      # since zero-filled placeholder vectors would break similarity search.
      # A full rebuild (including re-embedding) requires a separate workflow.
      def rebuild_schema!
        Rails.logger.warn(
          message: "knowledge.qdrant.rebuild_started",
          project_id: project.id,
          collection: collection_name
        )

        drop_collection!
        ensure_collection!

        Knowledge::Provenance::AuditLog.record(
          event: :collection_rebuilt,
          project: project,
          actor: { type: "system" },
          details: { collection_name: collection_name }
        )
      end

      def collection_name
        self.class.collection_name(project)
      end

      def self.collection_name(project)
        "account_#{project.account_id}_project_#{project.id}"
      end

      private

      def self.legacy_collection_name(project)
        "project_#{project.id}"
      end

      def collection_exists?(name = collection_name)
        result = client.collections.get(collection_name: name)
        result.dig("result", "status") == "green" || result.dig("result").present?
      rescue ::Qdrant::Error => e
        raise unless e.message.match?(/not found/i)

        Rails.logger.debug(
          message: "knowledge.qdrant.collection_not_found",
          collection: name,
          error: e.message
        )
        false
      end

      def legacy_collection_exists?
        collection_exists?(legacy_collection_name)
      end

      def alias_legacy_collection!
        client.collections.update_aliases(
          actions: [
            {
              create_alias: {
                collection_name: legacy_collection_name,
                alias_name: collection_name
              }
            }
          ]
        )

        Rails.logger.info(
          message: "knowledge.qdrant.legacy_collection_aliased",
          project_id: project.id,
          legacy_collection: legacy_collection_name,
          collection: collection_name
        )
      end

      def create_collection!
        client.collections.create(
          collection_name: collection_name,
          vectors: {
            size: embedding_dimensions,
            distance: "Cosine"
          }
        )
      end

      def create_payload_indexes!
        PAYLOAD_INDEX_SCHEMAS.each do |field, schema|
          client.collections.create_index(
            collection_name: collection_name,
            field_name: field,
            field_schema: schema
          )
        end
      end

      def embedding_dimensions
        Paid.embedding_dimensions
      end

      def legacy_collection_name
        self.class.legacy_collection_name(project)
      end
    end
  end
end
