# frozen_string_literal: true

class EmbedChunksJob < ApplicationJob
  queue_as :knowledge

  retry_on Knowledge::Embeddings::EmbeddingError, wait: :polynomially_longer, attempts: 5
  retry_on QdrantClient::ConnectionError, wait: :polynomially_longer, attempts: 5

  def perform(project_id = nil)
    project = project_id ? Project.find(project_id) : nil
    api_key = resolve_api_key(project)

    Knowledge::Embeddings::Pipeline.call(project: project, api_key: api_key)
  end

  private

  def resolve_api_key(project)
    return nil unless project

    project.effective_owner
      &.provider_api_keys
      &.for_api_service_type("openai")
      &.order(created_at: :desc)
      &.first
      &.api_key
  end
end
