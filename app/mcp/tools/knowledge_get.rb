# frozen_string_literal: true

module Tools
  # @spec KNOWLEDGE-AGENT-TOOLS-004
  class KnowledgeGet < KnowledgeBaseTool
    MAX_CHUNKS = 40
    CHUNK_CONTENT_LIMIT = 4000

    def self.tool_name = "paid_knowledge_get"

    def self.description
      "Fetch a single knowledge artifact by ID, including its active content chunks."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          artifact_id: { type: "integer", description: "The knowledge artifact ID" }
        },
        required: %w[project_id artifact_id]
      }
    end

    def perform(project_id:, artifact_id:)
      project = project_for(project_id)
      artifact = project.knowledge_artifacts.find(artifact_id)
      chunks = artifact.knowledge_chunks.where(status: %w[active stale]).order(:sequence, :created_at)
      chunk_count = chunks.count

      {
        artifact_id: artifact.id,
        uri: knowledge_uri(project: project, artifact_type: artifact.artifact_type, artifact_id: artifact.id),
        artifact_type: artifact.artifact_type,
        identifier: artifact.identifier,
        scope_path: artifact.scope_path,
        status: artifact.status,
        collector_type: artifact.collector_type,
        project_version: version_info(artifact.collector_run&.project_version),
        chunk_count: chunk_count,
        truncated: chunk_count > MAX_CHUNKS,
        chunks: chunks.first(MAX_CHUNKS).map { |chunk| summarize_chunk(chunk) }
      }
    end

    private

    def summarize_chunk(chunk)
      {
        chunk_id: chunk.id,
        chunk_type: chunk.chunk_type,
        sequence: chunk.sequence,
        status: chunk.status,
        content: chunk.content.to_s.truncate(CHUNK_CONTENT_LIMIT),
        scope_tags: chunk.scope_tags || []
      }
    end

    def version_info(version)
      return {} unless version

      { commit_sha: version.commit_sha, committed_at: version.committed_at&.iso8601 }
    end
  end
end
