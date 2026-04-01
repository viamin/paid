# frozen_string_literal: true

module Knowledge
  class Search
    class Hybrid
      attr_reader :project, :query, :artifact_type, :version, :limit, :api_key

      def initialize(project:, query:, artifact_type: nil, version: nil, limit: 20, api_key: nil)
        @project = project
        @query = query
        @artifact_type = artifact_type
        @version = version
        @limit = limit
        @api_key = api_key
      end

      def self.call(...)
        new(...).call
      end

      def call
        exact_results = Exact.call(
          project: project, query: query,
          artifact_type: artifact_type, limit: limit
        )
        semantic_results = Semantic.call(
          project: project, query: query,
          artifact_type: artifact_type, limit: limit, api_key: api_key
        )

        merged = deduplicate(exact_results, semantic_results)
        ranked = Reranker.call(results: merged, target_sha: version)

        {
          results: ranked.first(limit),
          exact_count: exact_results.size,
          semantic_count: semantic_results.size
        }
      end

      private

      def deduplicate(exact_results, semantic_results)
        seen = Set.new
        merged = []

        exact_results.each do |result|
          seen << result[:chunk_id]
          merged << result.merge(source: "hybrid")
        end

        semantic_results.each do |result|
          next if seen.include?(result[:chunk_id])

          seen << result[:chunk_id]
          merged << result.merge(source: "hybrid")
        end

        merged
      end
    end
  end
end
