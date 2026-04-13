# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

module AgentHarness
  module Providers
    # Base provider for OpenAI-compatible embedding APIs.
    class OpenaiCompatible < Base
      class HttpError < StandardError
        attr_reader :status, :body, :headers

        def initialize(status:, body:, headers:)
          @status = status
          @body = body
          @headers = headers
          super("HTTP #{status}: #{body}")
        end
      end

      class << self
        def binary_name
          "http"
        end

        def available?
          true
        end

        def supports_embeddings?
          true
        end
      end

      def embed(texts:, model:, dimensions: nil, **options)
        raise ArgumentError, "texts must be an Array" unless texts.is_a?(Array)

        options = normalize_provider_runtime(options)
        runtime = options[:provider_runtime]
        timeout = options[:timeout] || @config.timeout || default_timeout

        return empty_response(model: model, dimensions: dimensions) if texts.empty?

        start_time = Time.now
        response = perform_embedding_request(
          texts: texts,
          model: model,
          dimensions: dimensions,
          runtime: runtime,
          timeout: timeout
        )
        duration = Time.now - start_time

        body = parse_json_body(response.body)
        vectors = body.fetch("data").sort_by { |entry| entry.fetch("index") }.map { |entry| entry.fetch("embedding") }
        token_count = body.dig("usage", "total_tokens") || 0

        embedding_response = EmbeddingResponse.new(
          vectors: vectors,
          token_count: token_count,
          duration: duration,
          provider: self.class.provider_name,
          model: body["model"] || model,
          dimensions: dimensions || vectors.first&.length,
          metadata: {headers: response.to_hash}
        )

        track_embedding_tokens(embedding_response)
        embedding_response
      rescue JSON::ParserError => e
        raise ProviderError.new("Failed to parse embedding response: #{e.message}", original_error: e)
      rescue RateLimitError, AuthenticationError, TimeoutError, ProviderError
        raise
      rescue => e
        handle_openai_compatible_error(e)
      end

      def configuration_schema
        {
          fields: [
            {key: :base_url, type: :string, required: false, description: "Base API URL override"},
            {key: :api_key, type: :secret, required: false, description: "API key override"},
            {key: :api_key_env_var, type: :string, required: false, description: "Environment variable containing the API key"},
            {key: :model, type: :string, required: false, description: "Default embedding model"},
            {key: :api_version, type: :string, required: false, description: "API version for Azure OpenAI"},
            {key: :deployment, type: :string, required: false, description: "Deployment name for Azure OpenAI"}
          ],
          auth_modes: [:api_key],
          openai_compatible: true
        }
      end

      def error_patterns
        COMMON_ERROR_PATTERNS
      end

      protected

      def build_env(_options)
        {}
      end

      private

      def perform_embedding_request(texts:, model:, dimensions:, runtime:, timeout:)
        uri = build_embeddings_uri(model: model, runtime: runtime)
        request = Net::HTTP::Post.new(uri)
        build_headers(runtime: runtime).each { |key, value| request[key] = value }
        request.body = JSON.generate(embedding_payload(texts: texts, model: model, dimensions: dimensions))

        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: timeout,
          read_timeout: timeout
        ) do |http|
          response = http.request(request)
          raise http_error(response) unless response.is_a?(Net::HTTPSuccess)

          response
        end
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError.new(e.message, original_error: e)
      end

      def embedding_payload(texts:, model:, dimensions:)
        payload = {input: texts, model: model}
        payload[:dimensions] = dimensions if dimensions
        payload
      end

      def build_embeddings_uri(model:, runtime:)
        base = runtime&.base_url || @config.base_url || default_base_url
        base_uri = URI.parse(base)
        path, query = combine_path_and_query(base_uri.path, embeddings_path(model: model, runtime: runtime))
        base_uri.path = path
        base_uri.query = query
        base_uri
      end

      def embeddings_path(model:, runtime:)
        "/v1/embeddings"
      end

      def build_headers(runtime:)
        headers = {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{api_key(runtime)}"
        }
        headers["OpenAI-Organization"] = @config.organization if @config.organization
        headers.merge!(stringify_headers(@config.extra_headers))
        headers.merge!(stringify_headers(runtime_headers(runtime)))
        headers
      end

      def runtime_headers(runtime)
        return {} unless runtime

        runtime.metadata[:headers] || runtime.metadata["headers"] || {}
      end

      def stringify_headers(headers)
        headers.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_s] = value.to_s
        end
      end

      def api_key(runtime)
        runtime_key = runtime&.env&.[](api_key_env_var)
        return runtime_key if present?(runtime_key)
        return @config.api_key if present?(@config.api_key)

        env_key = ENV[api_key_env_var]
        return env_key if present?(env_key)

        raise AuthenticationError.new("No API key configured for #{self.class.provider_name}", provider: self.class.provider_name)
      end

      def api_key_env_var
        @config.api_key_env_var || self.class::API_KEY_ENV_VAR
      end

      def default_base_url
        self.class::DEFAULT_BASE_URL
      end

      def parse_json_body(body)
        JSON.parse(body)
      end

      def handle_openai_compatible_error(error)
        if error.is_a?(HttpError)
          raise classify_http_error(error)
        end

        classification = ErrorTaxonomy.classify(error, error_patterns)
        raise map_to_error_class(classification, error)
      end

      def classify_http_error(error)
        body_message = extract_error_message(error.body)

        case error.status
        when 401, 403
          AuthenticationError.new(body_message, provider: self.class.provider_name, context: {status: error.status})
        when 429
          RateLimitError.new(
            body_message,
            provider: self.class.provider_name,
            reset_time: retry_reset_time(error.headers),
            context: {status: error.status}
          )
        when 408
          TimeoutError.new(body_message, context: {status: error.status})
        else
          ProviderError.new(body_message, context: {status: error.status})
        end
      end

      def retry_reset_time(headers)
        retry_after = headers["retry-after"]&.first
        return unless present?(retry_after)

        seconds = Float(retry_after)
        Time.now + seconds
      rescue ArgumentError
        begin
          Time.httpdate(retry_after)
        rescue ArgumentError, TypeError
          nil
        end
      rescue TypeError
        nil
      end

      def extract_error_message(body)
        parsed = JSON.parse(body)
        parsed.dig("error", "message") || parsed["message"] || body
      rescue JSON::ParserError
        body
      end

      def http_error(response)
        HttpError.new(status: response.code.to_i, body: response.body.to_s, headers: response.to_hash)
      end

      def track_embedding_tokens(response)
        AgentHarness.token_tracker.record(
          provider: self.class.provider_name,
          model: response.model,
          input_tokens: response.token_count,
          output_tokens: 0,
          total_tokens: response.token_count
        )
      end

      def empty_response(model:, dimensions:)
        EmbeddingResponse.new(
          vectors: [],
          token_count: 0,
          duration: 0.0,
          provider: self.class.provider_name,
          model: model,
          dimensions: dimensions,
          metadata: {}
        )
      end

      def present?(value)
        value.is_a?(String) ? !value.strip.empty? : !value.nil?
      end

      def combine_path_and_query(base_path, request_path)
        path, query = request_path.split("?", 2)
        path = if base_path && !base_path.empty? && base_path != "/"
          "#{base_path.sub(%r{/$}, "")}/#{path.sub(%r{\A/}, "")}"
        else
          path.start_with?("/") ? path : "/#{path}"
        end

        [path, query]
      end
    end
  end
end
