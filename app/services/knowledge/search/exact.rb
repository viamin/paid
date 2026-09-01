# frozen_string_literal: true

module Knowledge
  class Search
    class Exact
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
        artifacts = KnowledgeArtifact
          .active
          .for_project(project)

        artifacts = artifacts.by_type(artifact_type) if artifact_type.present?

        quoted_query = KnowledgeArtifact.connection.quote(query)
        fallback_condition = fallback_condition_for(artifacts)
        exact_matches = artifacts
          .where(fallback_condition)
          .order(
            Arel.sql("CASE WHEN identifier = #{quoted_query} THEN 0 ELSE 1 END"),
            Arel.sql("similarity(identifier, #{quoted_query}) DESC"),
            :id
          )

        results = exact_matches
          .limit(limit)
          .includes(active_ordered_chunks: [ :outgoing_links, :incoming_links ], collector_run: :project_version)
          .flat_map { |artifact| format_artifact_results(artifact) }

        results.first(limit)
      end

      private

      def fallback_condition_for(artifacts)
        exact_match_sql = artifacts.where(identifier: query).select(1).limit(1).to_sql

        KnowledgeArtifact.sanitize_sql_array([
          "identifier = :query OR (identifier % :query AND NOT EXISTS (#{exact_match_sql}))",
          query: query
        ])
      end

      def format_artifact_results(artifact)
        version = artifact.collector_run&.project_version

        artifact.active_ordered_chunks.map do |chunk|
          build_result(chunk, artifact, version)
        end
      end

      def build_result(chunk, artifact, version)
        {
          chunk_id: chunk.id,
          artifact_id: artifact.id,
          artifact_type: artifact.artifact_type,
          identifier: artifact.identifier,
          scope_path: artifact.scope_path,
          content: chunk.content,
          score: 1.0,
          source: "exact",
          uri: chunk.knowledge_uri,
          artifact_uri: artifact.knowledge_uri,
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
    end
  end
end
