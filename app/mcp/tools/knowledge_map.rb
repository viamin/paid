# frozen_string_literal: true

module Tools
  # @spec KNOWLEDGE-AGENT-TOOLS-001
  class KnowledgeMap < KnowledgeBaseTool
    def self.tool_name = "paid_knowledge_map"

    def self.description
      "Get an overview of a project's knowledge base: artifact counts (active and stale) " \
        "grouped by type, plus top scope paths. Matches the api/knowledge_map overview."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID to map" }
        },
        required: %w[project_id]
      }
    end

    def perform(project_id:)
      project = project_for(project_id)
      overview = Knowledge::Map::Build.call(project: project)
      artifact_types = overview[:artifact_counts]
        .map { |artifact_type, counts| { artifact_type: artifact_type, count: counts.values.sum } }
        .sort_by { |entry| -entry[:count] }

      {
        project_id: project.id,
        total_artifacts: artifact_types.sum { |entry| entry[:count] },
        artifact_types: artifact_types,
        top_scopes: overview[:top_scopes]
      }
    end
  end
end
