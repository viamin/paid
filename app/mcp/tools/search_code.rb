# frozen_string_literal: true

module Tools
  class SearchCode < BaseTool
    def self.tool_name = "search_code"

    def self.description
      "Search code across a project's knowledge base using semantic or keyword search."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID to search within" },
          query: { type: "string", description: "The search query" },
          limit: { type: "integer", description: "Max results (default 10)", default: 10 }
        },
        required: %w[project_id query]
      }
    end

    def call(project_id:, query:, limit: 10)
      project = policy_scope(Project).find(project_id)
      authorize project, :show?

      search_limit = limit.to_i.clamp(1, 50)
      provider_config = project.knowledge_embedding_provider_configuration

      result = Knowledge::Search.call(
        project: project,
        query: query,
        mode: "hybrid",
        limit: search_limit,
        api_key: provider_config&.api_key,
        api_base_url: provider_config&.api_base_url
      )

      result[:results].map do |r|
        {
          id: r[:id],
          artifact_type: r[:artifact_type],
          name: r[:identifier],
          path: r[:scope_path],
          score: r[:score],
          content_preview: r[:content].to_s.truncate(500)
        }
      end
    end
  end
end
