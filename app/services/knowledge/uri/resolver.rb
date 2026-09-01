# frozen_string_literal: true

module Knowledge
  class Uri
    # Resolves a parsed/raw Paid KB URI back to its KnowledgeChunk or
    # KnowledgeArtifact, scoped to a project the caller has already
    # authorized. The URI's embedded project id must match that project —
    # a URI can't be used to reach into a project the caller wasn't already
    # authorized for.
    #
    # @spec KNOWLEDGE-URI-002
    class Resolver
      class ProjectMismatchError < StandardError; end

      def self.call(uri_or_string, project:)
        new(uri_or_string, project: project).call
      end

      def initialize(uri_or_string, project:)
        @parsed = uri_or_string.is_a?(Uri::Artifact) || uri_or_string.is_a?(Uri::Chunk) ? uri_or_string : Uri.parse(uri_or_string)
        @project = project
      end

      def call
        unless parsed.project_id.to_s == project.id.to_s
          raise ProjectMismatchError, "knowledge URI belongs to a different project"
        end

        parsed.kind == :chunk ? resolve_chunk : resolve_artifact
      end

      private

      attr_reader :parsed, :project

      def resolve_chunk
        KnowledgeChunk.for_project(project).find_by(id: parsed.chunk_id)
      end

      def resolve_artifact
        parsed.commit_sha.present? ? resolve_versioned_artifact : resolve_active_artifact
      end

      def resolve_active_artifact
        KnowledgeArtifact
          .active
          .for_project(project)
          .find_by(artifact_type: parsed.artifact_type, scope_path: parsed.scope_path, identifier: parsed.identifier)
      end

      def resolve_versioned_artifact
        KnowledgeArtifact
          .for_project(project)
          .joins(collector_run: :project_version)
          .where(artifact_type: parsed.artifact_type, scope_path: parsed.scope_path, identifier: parsed.identifier)
          .where(project_versions: { commit_sha: parsed.commit_sha })
          .order(id: :desc)
          .first
      end
    end
  end
end
