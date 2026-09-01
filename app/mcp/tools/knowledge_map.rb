# frozen_string_literal: true

module Tools
  # @spec KNOWLEDGE-AGENT-TOOLS-001
  class KnowledgeMap < KnowledgeBaseTool
    def self.tool_name = "paid_knowledge_map"

    def self.description
      "Get an overview of a project's knowledge base: active artifact counts grouped by type."
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
      artifact_types = KnowledgeArtifact.active.for_project(project)
        .group(:artifact_type)
        .count
        .sort_by { |_, count| -count }
        .map { |artifact_type, count| { artifact_type: artifact_type, count: count } }

      {
        project_id: project.id,
        total_artifacts: artifact_types.sum { |entry| entry[:count] },
        artifact_types: artifact_types
      }
    end
  end
end
