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

      # True when the project's Qdrant collection exists and contains at
      # least one *searchable* (`status: active`) point. Catches the failure
      # mode where PostgreSQL chunks still carry an `embedding_model` value
      # (so a PG-side existence check would look healthy) but the collection
      # was dropped, never populated, or recreated by `rebuild_schema!`
      # without re-upserting points — in those states a vector search would
      # silently return zero hits even though the rest of the pipeline
      # reports success. Probing for `status: active` points (rather than the
      # collection's total `vectors_count`) also catches the case where every
      # point has been flipped to `stale` in Postgres without being deleted
      # from Qdrant: `Semantic#search_qdrant` filters hits to `status:
      # active`, so a collection with only stale points contributes nothing
      # to search even though `vectors_count` is positive.
      def self.collection_populated?(project, client: Paid.qdrant_client)
        new(project: project, client: client).collection_populated?
      end

      def ensure_collection!
        existing_collection = collection_exists?

        if legacy_collection_exists?
          migrate_legacy_collection!
          alias_legacy_collection! unless existing_collection
          return
        end

        return if existing_collection

        create_collection!
        create_payload_indexes!
      end

      def drop_collection!
        return unless collection_exists?

        client.collections.delete(collection_name: collection_name)
      end

      # Uses a limit-1 scroll, not `points.count`: this gate runs before
      # every semantic/hybrid search, and an `exact: true` count makes Qdrant
      # visit the full active set — O(n) on collections with hundreds of
      # thousands of points. A filtered limit-1 scroll rides the `status`
      # payload index and stops at the first match, so it stays constant-cost
      # regardless of collection size. (`exact: false` counts come from
      # cardinality estimators and can misreport near-empty collections,
      # which would reintroduce this exact bug as flakiness.)
      def collection_populated?(name = collection_name)
        result = client.points.scroll(
          collection_name: name,
          limit: 1,
          filter: { must: [ { key: "status", match: { value: "active" } } ] },
          with_payload: false
        )
        result.dig("result", "points").to_a.any?
      rescue ::Qdrant::Error => e
        raise unless e.message.match?(/not found/i)

        Rails.logger.debug(
          message: "knowledge.qdrant.collection_not_found",
          collection: name,
          error: e.message
        )
        false
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

      def migrate_legacy_collection!
        create_payload_index!(legacy_collection_name, "account_id", PAYLOAD_INDEX_SCHEMAS.fetch("account_id"))
        backfill_legacy_account_payload!
      end

      def backfill_legacy_account_payload!
        client.points.set_payload(
          collection_name: legacy_collection_name,
          payload: { account_id: project.account_id },
          filter: {},
          wait: true
        )

        Rails.logger.info(
          message: "knowledge.qdrant.legacy_collection_payload_backfilled",
          project_id: project.id,
          account_id: project.account_id,
          legacy_collection: legacy_collection_name
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
          create_payload_index!(collection_name, field, schema)
        end
      end

      def create_payload_index!(target_collection_name, field, schema)
        client.collections.create_index(
          collection_name: target_collection_name,
          field_name: field,
          field_schema: schema
        )
      rescue ::Qdrant::Error => e
        raise unless e.message.match?(/already exists/i)

        Rails.logger.debug(
          message: "knowledge.qdrant.payload_index_exists",
          collection: target_collection_name,
          field_name: field
        )
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
