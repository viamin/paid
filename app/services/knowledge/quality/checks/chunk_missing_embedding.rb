# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Flags active chunks without an embedding_model recorded. These chunks
    # can still match lexical search but are invisible to semantic retrieval.
    # The embedding pipeline normally backfills missing embeddings; a
    # persistent finding means the pipeline is broken or the chunk is being
    # ignored for another reason.
    class Checks::ChunkMissingEmbedding < Checks::Base
      code "chunk_missing_embedding"
      severity "warning"

      def findings
        results = []
        KnowledgeChunk
          .active
          .for_project(project)
          .includes(:knowledge_artifact)
          .where(embedding_model: nil)
          .find_each(batch_size: 200) do |chunk|
            results << build_finding(
              target_type: "KnowledgeChunk",
              target_id: chunk.id,
              artifact_type: chunk.knowledge_artifact&.artifact_type,
              detail: "active chunk has no embedding"
            )
          end

        results
      end
    end
  end
end
