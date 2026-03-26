# frozen_string_literal: true

class EmbedChunksJob < ApplicationJob
  queue_as :knowledge

  retry_on Knowledge::Embeddings::EmbeddingError, wait: :polynomially_longer, attempts: 5
  retry_on QdrantClient::ConnectionError, wait: :polynomially_longer, attempts: 5

  def perform(project_id = nil)
    project = project_id ? Project.find(project_id) : nil

    Knowledge::Embeddings::Pipeline.call(project: project)
  end
end
