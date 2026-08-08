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
      MAX_RETRIES = 3
      BASE_DELAY = 1.0

      # Backward-compatible aliases. Older callers and tests still reference
      # the +MODEL+ and +DIMENSIONS+ constants; they are now the defaults, not
      # the only values the class accepts.
      MODEL = DEFAULT_MODEL
      DIMENSIONS = DEFAULT_DIMENSIONS
      COST_PER_MILLION_TOKENS = DEFAULT_COST_PER_MILLION_TOKENS

      attr_reader :model, :dimensions

      RETRYABLE_PROVIDER_STATUSES = [ 500, 502, 503, 504 ].freeze
      RETRYABLE_PROVIDER_ERRORS = [
        EOFError,
        IOError,
        OpenSSL::SSL::SSLError,
        SocketError,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET
      ].freeze

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

        self.class.results_from_body(request_embeddings(texts))
      end

      Result = Struct.new(:vector, :token_count, keyword_init: true)

      def self.results_from_body(body)
        embeddings = body.fetch("data").sort_by { |d| d["index"] }
        return [] if embeddings.empty?

        total_tokens = body.dig("usage", "total_tokens") || 0

        embeddings.map do |entry|
          Result.new(
            vector: entry.fetch("embedding"),
            token_count: total_tokens / embeddings.size
          )
        end
      end

      private

      def request_embeddings(texts)
        retries = 0

        begin
          AgentHarness.embed(
            texts,
            model: model,
            dimensions: dimensions,
            base_url: normalized_base_url,
            api_key: api_key,
            headers: request_headers,
            timeout:
          )
        rescue AgentHarness::AuthenticationError => e
          raise EmbeddingError, "Embedding API request failed: #{e.message}"
        rescue AgentHarness::RateLimitError, AgentHarness::TimeoutError => e
          retry_request(error: e, retries: retries) { |count| retries = count }
          retry
        rescue AgentHarness::ProviderError => e
          raise EmbeddingError, "Embedding API request failed: #{e.message}" unless retryable_provider_error?(e)

          retry_request(error: e, retries: retries) { |count| retries = count }
          retry
        end
      end

      def retry_request(error:, retries:)
        retries += 1
        if retries <= MAX_RETRIES
          sleep(retry_delay(error, retries))
          yield(retries)
          return
        end

        raise EmbeddingError, "Embedding API request failed after #{MAX_RETRIES} retries: #{error.message}"
      end

      # Respects Retry-After header when present, otherwise uses exponential backoff.
      def retry_delay(error, attempt)
        retry_after = error.context.dig(:headers, "retry-after")
        return retry_after.to_f if retry_after.present?

        BASE_DELAY * (2**(attempt - 1))
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

      def retryable_provider_error?(error)
        status = error.context[:status]
        return RETRYABLE_PROVIDER_STATUSES.include?(status) if status

        RETRYABLE_PROVIDER_ERRORS.any? { |klass| error.original_error.is_a?(klass) }
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
