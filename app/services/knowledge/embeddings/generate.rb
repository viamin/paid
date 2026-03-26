# frozen_string_literal: true

module Knowledge
  module Embeddings
    class Generate
      MODEL = "text-embedding-3-large"
      DIMENSIONS = 3_072
      COST_PER_MILLION_TOKENS = 0.13
      MAX_RETRIES = 3
      BASE_DELAY = 1.0
      RETRYABLE_STATUSES = [ 429, 500, 502, 503, 504 ].freeze

      attr_reader :model, :dimensions

      def initialize(model: MODEL, dimensions: DIMENSIONS)
        @model = model
        @dimensions = dimensions
      end

      def self.call(texts:, model: MODEL, dimensions: DIMENSIONS)
        new(model: model, dimensions: dimensions).call(texts: texts)
      end

      # Returns an array of Result structs with :vector and :token_count
      def call(texts:)
        return [] if texts.empty?

        response = request_embeddings(texts)
        body = parse_response(response)

        embeddings = body.fetch("data").sort_by { |d| d["index"] }
        total_tokens = body.dig("usage", "total_tokens") || 0

        embeddings.map do |entry|
          Result.new(
            vector: entry.fetch("embedding"),
            token_count: total_tokens / embeddings.size
          )
        end
      end

      Result = Struct.new(:vector, :token_count, keyword_init: true)

      private

      def request_embeddings(texts)
        retries = 0

        begin
          response = connection.post("/v1/embeddings") do |req|
            req.body = {
              input: texts,
              model: model,
              dimensions: dimensions
            }.to_json
          end

          if !response.success? && RETRYABLE_STATUSES.include?(response.status)
            raise RetryableHTTPError, response
          end

          response
        rescue Faraday::Error, RetryableHTTPError => e
          retries += 1
          if retries <= MAX_RETRIES
            delay = retry_delay(e, retries)
            sleep(delay)
            retry
          end
          raise EmbeddingError, "Embedding API request failed after #{MAX_RETRIES} retries: #{e.message}"
        end
      end

      # Respects Retry-After header when present, otherwise uses exponential backoff.
      def retry_delay(error, attempt)
        if error.is_a?(RetryableHTTPError) && (retry_after = error.response.headers["retry-after"])
          retry_after.to_f
        else
          BASE_DELAY * (2**(attempt - 1))
        end
      end

      # Internal error to trigger retry on retryable HTTP statuses.
      class RetryableHTTPError < StandardError
        attr_reader :response

        def initialize(response)
          @response = response
          super("HTTP #{response.status}: #{response.body}")
        end
      end

      def parse_response(response)
        unless response.success?
          raise EmbeddingError, "Embedding API returned #{response.status}: #{response.body}"
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise EmbeddingError,
          "Failed to parse embedding API response as JSON: #{e.message} (status #{response.status}, body: #{response.body})"
      end

      # TODO(#257): Replace with AgentHarness.embed once embedding support is added
      # to the agent-harness gem. This direct OpenAI call is a temporary bridge.
      def connection
        @connection ||= Faraday.new(url: api_base_url) do |f|
          f.request :retry, max: 0
          f.headers["Authorization"] = "Bearer #{api_key}"
          f.headers["Content-Type"] = "application/json"
          f.adapter Faraday.default_adapter
        end
      end

      def api_base_url
        ENV.fetch("OPENAI_API_BASE_URL", "https://api.openai.com")
      end

      def api_key
        ENV.fetch("OPENAI_API_KEY") do
          raise EmbeddingError,
            "OPENAI_API_KEY environment variable is required for embedding generation"
        end
      end

      def self.estimate_cost(token_count)
        (token_count.to_f / 1_000_000 * COST_PER_MILLION_TOKENS).round(6)
      end
    end
  end
end
