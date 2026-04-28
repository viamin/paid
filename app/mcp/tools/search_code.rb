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

      results = KnowledgeArtifact
        .where(project_id: project.id)
        .where("knowledge_artifacts.content ILIKE ?", "%#{sanitize_like(query)}%")
        .limit([ limit.to_i, 50 ].min)

      results.map do |artifact|
        {
          id: artifact.id,
          artifact_type: artifact.artifact_type,
          name: artifact.identifier,
          path: artifact.scope_path,
          content_preview: artifact.content&.truncate(500)
        }
      end
    end

    private

    def sanitize_like(value)
      value.gsub(/[%_\\]/) { |m| "\\#{m}" }
    end
  end
end
