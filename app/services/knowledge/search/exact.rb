# frozen_string_literal: true

module Knowledge
  class Search
    class Exact
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

        exact_matches = artifacts.where(identifier: query)

        unless exact_matches.exists?
          exact_matches = artifacts.identifier_like(query)
        end

        exact_matches
          .limit(limit)
          .includes(active_ordered_chunks: [ :outgoing_links, :incoming_links ], collector_run: :project_version)
          .flat_map { |artifact| format_artifact_results(artifact) }
      end

      private

      def format_artifact_results(artifact)
        version = artifact.collector_run&.project_version

        artifact.active_ordered_chunks.map do |chunk|
          build_result(chunk, artifact, version)
        end
      end

      def build_result(chunk, artifact, version)
        {
          chunk_id: chunk.id,
          artifact_type: artifact.artifact_type,
          identifier: artifact.identifier,
          content: chunk.content,
          score: 1.0,
          source: "exact",
          project_version: version_info(version),
          scope_tags: chunk.scope_tags || [],
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
