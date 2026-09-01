# frozen_string_literal: true

module Tools
  # @spec KNOWLEDGE-AGENT-TOOLS-003
  class KnowledgeSearch < KnowledgeBaseTool
    DEFAULT_LIMIT = 10
    MAX_LIMIT = 25
    CONTENT_LIMIT = 800

    def self.tool_name = "paid_knowledge_search"

    def self.description
      "Search a project's knowledge base by query using exact, semantic, or hybrid retrieval."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID to search within" },
          query: { type: "string", description: "The search query" },
          mode: { type: "string", enum: Knowledge::Search::MODES, description: "Retrieval mode (default #{Knowledge::Search::DEFAULT_MODE})" },
          artifact_type: { type: "string", description: "Optional artifact type filter" },
          limit: { type: "integer", description: "Max results (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT})", default: DEFAULT_LIMIT }
        },
        required: %w[project_id query]
      }
    end

    def perform(project_id:, query:, mode: Knowledge::Search::DEFAULT_MODE, artifact_type: nil, limit: DEFAULT_LIMIT)
      project = project_for(project_id)
      normalized_query = query.to_s.strip
      raise ArgumentError, "query is required" if normalized_query.blank?

      search = Knowledge::Search.call(
        project: project,
        query: normalized_query,
        mode: mode,
        artifact_type: artifact_type,
        limit: limit.to_i.clamp(1, MAX_LIMIT)
      )

      {
        project_id: project.id,
        results: search[:results].map { |result| summarize(project, result) },
        meta: search[:meta]
      }
    end

    private

    def summarize(project, result)
      {
        chunk_id: result[:chunk_id],
        artifact_id: result[:artifact_id],
        uri: knowledge_uri(project: project, artifact_type: result[:artifact_type], artifact_id: result[:artifact_id]),
        artifact_type: result[:artifact_type],
        identifier: result[:identifier],
        scope_path: result[:scope_path],
        content: result[:content].to_s.truncate(CONTENT_LIMIT),
        score: result[:score],
        source: result[:source]
      }
    end
  end
end
