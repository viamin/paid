# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Flags active chunks whose parent artifact has been deleted or otherwise
    # removed. The FK cascades so this should never happen in practice, but
    # the foreign-key check is cheap insurance and surfaces data-integrity
    # surprises. Severity: error (real bug if it fires).
    class Checks::OrphanedChunk < Checks::Base
      code "orphaned_chunk"
      severity "error"

      def collect_findings(collector)
        KnowledgeChunk
          .active
          .for_project(project)
          .where.missing(:knowledge_artifact)
          .find_each(batch_size: 200) do |chunk|
            add_finding(
              collector,
              target_type: "KnowledgeChunk",
              target_id: chunk.id,
              artifact_type: nil,
              detail: "active chunk has no parent artifact"
            )
          end
      end
    end
  end
end
