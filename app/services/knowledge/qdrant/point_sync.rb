# frozen_string_literal: true

module Knowledge
  module Qdrant
    class PointSync
      # Payload keys that must never be sent to Qdrant. Prevents accidental
      # storage of source code or secrets in the vector database.
      FORBIDDEN_PAYLOAD_KEYS = %w[content text body secret password token].freeze

      attr_reader :client

      def initialize(client: Paid.qdrant_client)
        @client = client
      end

      def self.upsert_chunk!(chunk, vector:, client: Paid.qdrant_client)
        new(client: client).upsert_chunk!(chunk, vector: vector)
      end

      def self.delete_chunks!(chunk_ids, project:, client: Paid.qdrant_client)
        new(client: client).delete_chunks!(chunk_ids, project: project)
      end

      # Accepts a project AR object (not just an ID) because collection_name
      # and filter construction both use project.id, keeping the interface
      # consistent with upsert_chunk!/delete_chunks! which also take AR objects.
      # Callers with only a project_id should use Project.find(id) first.
      def self.delete_by_filter!(project:, filters: {}, client: Paid.qdrant_client)
        new(client: client).delete_by_filter!(project: project, filters: filters)
      end

      def upsert_chunk!(chunk, vector:)
        artifact = chunk.knowledge_artifact
        payload = build_payload(chunk, artifact)
        validate_payload!(payload)

        client.points.upsert(
          collection_name: CollectionManager.collection_name(chunk.project),
          points: [
            {
              id: chunk.id,
              vector: vector,
              payload: payload
            }
          ],
          wait: true
        )
      end

      def delete_chunks!(chunk_ids, project:)
        return if chunk_ids.empty?

        client.points.delete(
          collection_name: CollectionManager.collection_name(project),
          points: chunk_ids.map(&:to_s),
          wait: true
        )
      end

      def delete_by_filter!(project:, filters: {})
        qdrant_filter = build_filter(project, filters)

        client.points.delete(
          collection_name: CollectionManager.collection_name(project),
          filter: qdrant_filter,
          wait: true
        )
      end

      private

      def validate_payload!(payload)
        forbidden = payload.keys.map(&:to_s) & FORBIDDEN_PAYLOAD_KEYS
        raise SecurityError, "Forbidden payload keys: #{forbidden.join(', ')}" if forbidden.any?
      end

      def build_payload(chunk, artifact)
        {
          project_id: chunk.project_id,
          project_version_id: artifact.collector_run.project_version_id,
          artifact_type: artifact.artifact_type,
          scope_tags: chunk.scope_tags || [],
          status: chunk.status,
          created_at: chunk.created_at&.iso8601
        }
      end

      def build_filter(project, filters)
        conditions = [
          { key: "project_id", match: { value: project.id } }
        ]

        filters.each do |key, value|
          conditions << { key: key.to_s, match: { value: value } }
        end

        { must: conditions }
      end
    end
  end
end
