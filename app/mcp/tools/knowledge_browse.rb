# frozen_string_literal: true

module Tools
  # @spec KNOWLEDGE-AGENT-TOOLS-002
  class KnowledgeBrowse < KnowledgeBaseTool
    DEFAULT_LIMIT = 25
    MAX_LIMIT = 100

    def self.tool_name = "paid_knowledge_browse"

    def self.description
      "List a project's active knowledge artifacts of one type, optionally filtered by a scope path prefix."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          artifact_type: { type: "string", description: "The artifact type to browse (see paid_knowledge_map)" },
          scope_path_prefix: { type: "string", description: "Optional scope path prefix filter, e.g. a directory" },
          limit: { type: "integer", description: "Max results (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT})", default: DEFAULT_LIMIT },
          offset: { type: "integer", description: "Pagination offset (default 0)", default: 0 }
        },
        required: %w[project_id artifact_type]
      }
    end

    def perform(project_id:, artifact_type:, scope_path_prefix: nil, limit: DEFAULT_LIMIT, offset: 0)
      project = project_for(project_id)
      scope = base_scope(project, artifact_type, scope_path_prefix)
      bounded_limit = limit.to_i.clamp(1, MAX_LIMIT)
      bounded_offset = [ offset.to_i, 0 ].max

      {
        project_id: project.id,
        artifact_type: artifact_type,
        total_count: scope.count,
        limit: bounded_limit,
        offset: bounded_offset,
        artifacts: paginated_artifacts(scope, bounded_limit, bounded_offset).map { |artifact| summarize(project, artifact) }
      }
    end

    private

    def base_scope(project, artifact_type, scope_path_prefix)
      scope = KnowledgeArtifact.active.for_project(project).by_type(artifact_type)
      return scope if scope_path_prefix.blank?

      scope.where("scope_path LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(scope_path_prefix)}%")
    end

    def paginated_artifacts(scope, limit, offset)
      scope
        .select(<<~SQL.squish)
          knowledge_artifacts.*,
          (
            SELECT COUNT(*)
            FROM knowledge_chunks
            WHERE knowledge_chunks.knowledge_artifact_id = knowledge_artifacts.id
              AND knowledge_chunks.status IN ('active', 'stale')
          ) AS chunk_count
        SQL
        .order(:scope_path, :identifier, :id)
        .offset(offset)
        .limit(limit)
    end

    def summarize(project, artifact)
      {
        artifact_id: artifact.id,
        uri: knowledge_uri(project: project, artifact_type: artifact.artifact_type, artifact_id: artifact.id),
        identifier: artifact.identifier,
        scope_path: artifact.scope_path,
        status: artifact.status,
        chunk_count: artifact.chunk_count.to_i,
        updated_at: artifact.updated_at
      }
    end
  end
end
