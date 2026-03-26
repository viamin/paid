# frozen_string_literal: true

class QdrantCollectionCleanupJob < ApplicationJob
  queue_as :default
  retry_on QdrantClient::ConnectionError, wait: :polynomially_longer, attempts: 5

  def perform(project_id)
    # Build a minimal struct since the project record is already destroyed
    project_stub = Struct.new(:id).new(project_id)
    Knowledge::Qdrant::CollectionManager.drop_collection!(project_stub)
  end
end
