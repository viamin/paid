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

      def collect_findings(collector)
        link_scope = KnowledgeLink
          .joins(source_chunk: :knowledge_artifact)
          .joins("LEFT JOIN knowledge_chunks target_chunks ON target_chunks.id = knowledge_links.target_chunk_id")
          .where(knowledge_artifacts: { project_id: project.id })
          .where("target_chunks.id IS NULL OR target_chunks.status = ?", "deleted")

        link_scope.find_each(batch_size: 200) do |link|
          add_finding(
            collector,
            target_type: "KnowledgeLink",
            target_id: link.id,
            detail: "link #{link.link_type} target_chunk=#{link.target_chunk_id} missing or deleted",
            extra: { source_chunk_id: link.source_chunk_id, target_chunk_id: link.target_chunk_id }
          )
        end
      end
    end
  end
end
