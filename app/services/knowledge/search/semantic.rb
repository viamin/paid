# frozen_string_literal: true

module Knowledge
  class Search
    class Semantic
      include LineRangeHelpers
      # @spec KNOWLEDGE-003

      attr_reader :project, :query, :artifact_type, :limit

      def initialize(project:, query:, artifact_type: nil, limit: 20)
        @project = project
        @query = query
        @artifact_type = artifact_type
        @limit = limit
      end

      def self.call(...)
        new(...).call
      end

      def call
        lexical_results = lexical_search
        vector_results = vector_search

        {
          results: merge_results(lexical_results, vector_results),
          vector_search_status: @vector_search_status
        }
      end

      private

      def lexical_search
        chunks = KnowledgeChunk
          .active
          .for_project(project)
          .full_text_search(query)

        if artifact_type.present?
          chunks = chunks.joins(:knowledge_artifact)
            .where(knowledge_artifacts: { artifact_type: artifact_type })
        end

        chunks.includes(:outgoing_links, :incoming_links, knowledge_artifact: { collector_run: :project_version })
          .limit(limit)
          .map { |chunk| format_chunk_result(chunk, score: chunk.relevance_rank&.to_f) }
      end

      # @spec KNOWLEDGE-010
      def vector_search
        return no_vector_search(:not_configured) unless qdrant_available?
        return no_vector_search(:unhealthy) unless qdrant_healthy?
        return no_vector_search(:no_embeddings) unless embedded_chunks_exist?

        embedding = generate_query_embedding
        return no_vector_search(:embedding_failed) if embedding.nil?

        @vector_search_status = "ok"
        hydrate_qdrant_results(search_qdrant(embedding))
      rescue StandardError => e
        Rails.logger.warn(
          message: "knowledge.search.vector_search_failed",
          project_id: project.id,
          error: e.message
        )
        no_vector_search(:error)
      end

      # Distinguishes "this query has no vector matches" (status ok, zero
      # hits) from "the vector half structurally cannot contribute" (any
      # other status) — the latter is what should read as degraded in meta.
      def no_vector_search(status)
        @vector_search_status = status.to_s
        []
      end

      def embedded_chunks_exist?
        KnowledgeChunk.embeddable.for_project(project).exists?
      end

      def search_qdrant(embedding)
        filter = { must: [ { key: "status", match: { value: "active" } } ] }

        if artifact_type.present?
          filter[:must] << { key: "artifact_type", match: { value: artifact_type } }
        end

        response = Paid.qdrant_client.points.search(
          collection_name: Qdrant::CollectionManager.collection_name(project),
          vector: embedding,
          filter: filter,
          limit: limit,
          with_payload: false
        )

        response.dig("result") || []
      end

      def hydrate_qdrant_results(results)
        chunk_ids = results.map { |r| r["id"] }
        score_map = results.each_with_object({}) { |r, h| h[r["id"]] = r["score"] }

        chunks = KnowledgeChunk
          .where(id: chunk_ids)
          .active
          .for_project(project)
          .includes(:outgoing_links, :incoming_links, knowledge_artifact: { collector_run: :project_version })

        chunks_by_id = chunks.index_by(&:id)

        chunk_ids.filter_map do |id|
          chunk = chunks_by_id[id]
          next unless chunk

          format_chunk_result(chunk, score: score_map[id])
        end
      end

      def merge_results(lexical, vector)
        seen = Set.new
        merged = []

        # Vector results are higher quality — prioritize them
        vector.each do |result|
          seen << result[:chunk_id]
          merged << result
        end

        lexical.each do |result|
          next if seen.include?(result[:chunk_id])

          seen << result[:chunk_id]
          merged << result
        end

        merged.first(limit)
      end

      def format_chunk_result(chunk, score:)
        artifact = chunk.knowledge_artifact
        version = artifact.collector_run&.project_version

        {
          chunk_id: chunk.id,
          artifact_id: artifact.id,
          artifact_type: artifact.artifact_type,
          identifier: artifact.identifier,
          scope_path: artifact.scope_path,
          content: chunk.content,
          score: score,
          source: "semantic",
          project_version: version_info(version),
          scope_tags: chunk.scope_tags || [],
          start_line: start_line_for(artifact),
          end_line: end_line_for(artifact),
          collector_run_id: artifact.collector_run_id,
          status: artifact.status,
          link_count: chunk.outgoing_links.size + chunk.incoming_links.size,
          created_at: chunk.created_at
        }
      end

      def version_info(version)
        return {} unless version

        {
          commit_sha: version.commit_sha,
          committed_at: version.committed_at&.iso8601
        }
      end

      def generate_query_embedding
        generator = Knowledge::Embeddings::ProxyGenerator.new(project: project, containerize: false)
        results = generator.call(texts: [ query ])
        results.first&.vector
      rescue StandardError => e
        Rails.logger.warn(
          message: "knowledge.search.embedding_generation_failed",
          error: e.message
        )
        nil
      ensure
        generator&.close
      end

      def qdrant_available?
        Paid.qdrant_url.present?
      end

      def qdrant_healthy?
        Paid.qdrant_client.healthy?
      rescue StandardError
        false
      end
    end
  end
end
