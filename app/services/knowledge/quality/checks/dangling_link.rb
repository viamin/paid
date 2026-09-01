# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Flags knowledge links whose target chunk is missing (or no longer
    # active) on the same project. The target's status matters because we
    # treat any non-deleted endpoint as reachable — a `redacted` chunk still
    # exists as a node in the graph.
    class Checks::DanglingLink < Checks::Base
      code "dangling_link"
      severity "warning"

      def findings
        results = []

        link_scope = KnowledgeLink
          .joins(source_chunk: :knowledge_artifact)
          .where(knowledge_artifacts: { project_id: project.id })

        link_scope.find_each(batch_size: 200) do |link|
          target = KnowledgeChunk.find_by(id: link.target_chunk_id)
          next if target && target.status != "deleted"

          results << build_finding(
            target_type: "KnowledgeLink",
            target_id: link.id,
            detail: "link #{link.link_type} target_chunk=#{link.target_chunk_id} missing or deleted",
            extra: { source_chunk_id: link.source_chunk_id, target_chunk_id: link.target_chunk_id }
          )
        end

        results
      end
    end
  end
end
