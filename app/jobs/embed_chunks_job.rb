# frozen_string_literal: true

class EmbedChunksJob < ApplicationJob
  queue_as :knowledge

  retry_on Knowledge::Embeddings::EmbeddingError, wait: :polynomially_longer, attempts: 5
  retry_on QdrantClient::ConnectionError, wait: :polynomially_longer, attempts: 5

  def perform(project_id = nil)
    project = project_id ? Project.find(project_id) : nil

    if project && !project.semantic_search_available?
      Rails.logger.info(
        message: "knowledge.embed_chunks.skipped",
        project_id: project.id,
        reason: "no_embedding_provider"
      )
      return
    end

    Knowledge::Embeddings::Pipeline.call(project: project)
  ensure
    # Busting covers the case where the pipeline flips newly-redacted chunks
    # from "active" to "redacted" while embedding the rest. Both the cached
    # artifact counts and the OKF export availability predicate depend on
    # chunk status; without this, a stale `Export OKF` link can linger on the
    # project page until the 10-minute TTL expires even though
    # `with_active_chunks` no longer matches the affected artifacts.
    KnowledgeArtifact.bust_artifact_counts_cache(project.id) if project
  end
end
