# frozen_string_literal: true

class EmbedChunksJob < ApplicationJob
  queue_as :knowledge

  retry_on Knowledge::Embeddings::EmbeddingError, wait: :polynomially_longer, attempts: 5
  retry_on QdrantClient::ConnectionError, wait: :polynomially_longer, attempts: 5

  def perform(project_id = nil)
    project = project_id ? Project.find(project_id) : nil
    provider_config = project&.knowledge_embedding_provider_configuration

    Knowledge::Embeddings::Pipeline.call(
      project: project,
      api_key: provider_config&.api_key,
      api_base_url: provider_config&.api_base_url
    )
  end
end
