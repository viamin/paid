# frozen_string_literal: true

module Knowledge
  module Embeddings
    class Generate
      # @spec KNOWLEDGE-EMBED-001
      # Default embedding model used when the user has not configured a
      # specific model on their user_settings. Matches the legacy hardcoded
      # value so existing knowledge bases continue to work without
      # re-embedding.
      DEFAULT_MODEL = "text-embedding-3-large".freeze
      # Default vector dimensions matching DEFAULT_MODEL's natural output.
      DEFAULT_DIMENSIONS = 3_072
      # Cost-per-million-tokens (USD) used by +estimate_cost+ when no model
      # catalog entry is available. This is a generic OpenAI-compatible
      # default; callers that need model-specific pricing can compute it
      # themselves.
      DEFAULT_COST_PER_MILLION_TOKENS = 0.13
      MAX_ATTEMPTS = 4

      # Backward-compatible aliases. Older callers and tests still reference
      # the +MODEL+ and +DIMENSIONS+ constants; they are now the defaults, not
      # the only values the class accepts.
      MODEL = DEFAULT_MODEL
      DIMENSIONS = DEFAULT_DIMENSIONS
      COST_PER_MILLION_TOKENS = DEFAULT_COST_PER_MILLION_TOKENS

      attr_reader :model, :dimensions

      def initialize(
        model: DEFAULT_MODEL,
        dimensions: DEFAULT_DIMENSIONS,
        cost_per_million_tokens: DEFAULT_COST_PER_MILLION_TOKENS,
        base_url:,
        headers: {},
        timeout: AgentHarness::OpenAICompatibleTransport::DEFAULT_TIMEOUT
      )
        @model = model
        @dimensions = dimensions
        @cost_per_million_tokens = cost_per_million_tokens
        @base_url = base_url
        @headers = headers
        @timeout = timeout
      end

      def self.call(
        texts:,
        model: DEFAULT_MODEL,
        dimensions: DEFAULT_DIMENSIONS,
        cost_per_million_tokens: DEFAULT_COST_PER_MILLION_TOKENS,
        base_url:,
        headers: {},
        timeout: AgentHarness::OpenAICompatibleTransport::DEFAULT_TIMEOUT
      )
        new(
          model: model,
          dimensions: dimensions,
          cost_per_million_tokens: cost_per_million_tokens,
          base_url: base_url,
          headers: headers,
          timeout: timeout
        ).call(texts: texts)
      end

      # Returns an array of Result structs with :vector and :token_count
      def call(texts:)
        return [] if texts.empty?

        self.class.results_from_response(request_embeddings(texts))
      end

      Result = Struct.new(:vector, :token_count, keyword_init: true)

      def self.results_from_body(body)
        embeddings = body.fetch("data").sort_by { |embedding| embedding["index"] }
        return [] if embeddings.empty?

        results_from_vectors(
          embeddings.map { |embedding| embedding.fetch("embedding") },
          body.dig("usage", "total_tokens") || 0
        )
      end

      def self.results_from_response(response)
        results_from_vectors(response.vectors, response.usage.fetch(:input_tokens) || 0)
      end

      def self.results_from_vectors(vectors, total_tokens)
        return [] if vectors.empty?

        vectors.map do |vector|
          Result.new(
            vector: vector,
            token_count: total_tokens / vectors.size
          )
        end
      end

      private

      # @spec KNOWLEDGE-EMBED-002
      def request_embeddings(texts)
        AgentHarness.embed(
          inputs: texts,
          model: model,
          dimensions: dimensions,
          endpoint: normalized_base_url,
          credentials: { api_key: api_key },
          headers: request_headers,
          timeout:,
          max_attempts: MAX_ATTEMPTS
        )
      rescue AgentHarness::Error => e
        raise EmbeddingError, "Embedding API request failed: #{e.message}", cause: e
      end

      attr_reader :base_url, :headers, :timeout

      def normalized_base_url
        base_url.to_s.sub(%r{/\z}, "")
      end

      def api_key
        headers.fetch("Authorization").to_s.sub(/\ABearer\s+/i, "")
      end

      def request_headers
        headers.except("Authorization").compact
      end

      def self.estimate_cost(token_count, cost_per_million_tokens: COST_PER_MILLION_TOKENS)
        (token_count.to_f / 1_000_000 * cost_per_million_tokens).round(6)
      end

      def estimate_cost(token_count)
        self.class.estimate_cost(token_count, cost_per_million_tokens: @cost_per_million_tokens)
      end
    end
  end
end
