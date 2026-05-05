# frozen_string_literal: true

class EmbedChunksJob < ApplicationJob
  queue_as :knowledge

  retry_on Knowledge::Embeddings::EmbeddingError, wait: :polynomially_longer, attempts: 5
  retry_on QdrantClient::ConnectionError, wait: :polynomially_longer, attempts: 5

  def perform(project_id = nil)
    project = project_id ? Project.find(project_id) : nil
    provider_config = project&.knowledge_embedding_provider_configuration

    if project && provider_config.nil?
      Rails.logger.info(
        message: "knowledge.embed_chunks.skipped",
        project_id: project.id,
        reason: "no_embedding_provider"
      )
      return
    end

    Knowledge::Embeddings::Pipeline.call(project: project)
  end
end
