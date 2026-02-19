# frozen_string_literal: true

module SemanticSearch
  # Generates vector embeddings for code chunks that don't have them yet.
  # Uses an external embedding API to convert text content into vectors.
  #
  # This is separated from indexing so that embedding generation can be
  # retried independently and rate-limited appropriately.
  #
  # @example
  #   SemanticSearch::GenerateEmbeddings.call(project: project, batch_size: 50)
  class GenerateEmbeddings
    DEFAULT_BATCH_SIZE = 50

    attr_reader :project, :batch_size, :stats

    def initialize(project:, batch_size: DEFAULT_BATCH_SIZE)
      @project = project
      @batch_size = batch_size
      @stats = { generated: 0, failed: 0 }
    end

    def self.call(...)
      new(...).call
    end

    def call
      chunks = project.code_chunks.without_embeddings.limit(batch_size)
      return stats if chunks.empty?

      chunks.each do |chunk|
        embedding = generate_embedding(chunk.content)
        if embedding
          chunk.update!(embedding: embedding)
          @stats[:generated] += 1
        else
          @stats[:failed] += 1
        end
      end

      log_completion
      stats
    end

    private

    def generate_embedding(text)
      # Placeholder for embedding API integration.
      # Phase 1 will use an external API (e.g., OpenAI text-embedding-3-small).
      # The embedding model and API configuration will be added when
      # the embedding provider is selected (see RDR-018 prerequisites).
      #
      # Example implementation with ruby-llm:
      #   RubyLLM.embed(text, model: "text-embedding-3-small").vectors
      #
      # Example implementation with HTTP client:
      #   response = Faraday.post("https://api.openai.com/v1/embeddings", {
      #     model: "text-embedding-3-small",
      #     input: text.truncate(8000)
      #   }.to_json, headers)
      #   JSON.parse(response.body).dig("data", 0, "embedding")
      Rails.logger.debug(
        message: "semantic_search.embedding_skipped",
        reason: "no_embedding_provider_configured"
      )
      nil
    end

    def log_completion
      Rails.logger.info(
        message: "semantic_search.embeddings_generated",
        project_id: project.id,
        generated: stats[:generated],
        failed: stats[:failed]
      )
    end
  end
end
