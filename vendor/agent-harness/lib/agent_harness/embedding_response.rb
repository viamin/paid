# frozen_string_literal: true

module AgentHarness
  # Response returned from embedding providers.
  class EmbeddingResponse
    attr_reader :vectors, :token_count, :duration, :provider, :model, :dimensions, :metadata

    def initialize(vectors:, token_count:, duration:, provider:, model:, dimensions: nil, metadata: {})
      @vectors = vectors
      @token_count = token_count
      @duration = duration
      @provider = provider.to_sym
      @model = model
      @dimensions = dimensions
      @metadata = metadata
    end

    def success?
      true
    end

    def to_h
      {
        vectors: @vectors,
        token_count: @token_count,
        duration: @duration,
        provider: @provider,
        model: @model,
        dimensions: @dimensions,
        metadata: @metadata
      }
    end

    def inspect
      "#<AgentHarness::EmbeddingResponse provider=#{@provider} vectors=#{@vectors.length} duration=#{@duration.round(2)}s>"
    end
  end
end
