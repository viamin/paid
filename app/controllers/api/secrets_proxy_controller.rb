# frozen_string_literal: true

module Api
  class SecretsProxyController < ActionController::API
    before_action :validate_container_request
    before_action :set_agent_run
    before_action :check_rate_limit

    # Maximum tokens per agent run before rate limiting kicks in
    MAX_TOKENS_PER_RUN = 10_000_000

    # POST /api/proxy/anthropic/*path
    def anthropic
      proxy_request(
        base_url: "https://api.anthropic.com",
        auth_header: "x-api-key",
        api_key: fetch_api_key(:anthropic)
      )
    end

    # POST /api/proxy/openai/*path
    def openai
      proxy_request(
        base_url: "https://api.openai.com",
        auth_header: "Authorization",
        api_key: "Bearer #{fetch_api_key(:openai)}"
      )
    end

    private

    def validate_container_request
      @agent_run_id = request.headers["X-Agent-Run-Id"]

      unless @agent_run_id.present?
        render json: { error: "Missing agent run ID" }, status: :unauthorized
      end
    end

    def set_agent_run
      @agent_run = AgentRun.find_by(id: @agent_run_id)

      unless @agent_run&.running?
        render json: { error: "Invalid or inactive agent run" }, status: :forbidden
      end
    end

    def check_rate_limit
      return unless @agent_run.total_tokens > MAX_TOKENS_PER_RUN

      render json: { error: "Token limit exceeded for this agent run" }, status: :too_many_requests
    end

    def proxy_request(base_url:, auth_header:, api_key:)
      path = params[:path] || ""
      target_url = "#{base_url}/#{path}"

      response = build_connection.run_request(
        request.method.downcase.to_sym,
        target_url,
        request.body.read,
        forwarded_headers.merge(auth_header => api_key)
      )

      track_usage(response)

      render body: response.body, status: response.status,
             content_type: response.headers["content-type"] || "application/json"
    rescue Faraday::Error => e
      log_error("secrets_proxy.forward_failed", e.message)
      render json: { error: "Upstream request failed" }, status: :bad_gateway
    end

    def build_connection
      Faraday.new do |f|
        f.options.timeout = 300
        f.options.open_timeout = 10
      end
    end

    def forwarded_headers
      %w[Content-Type Accept].each_with_object({}) do |header, hash|
        value = request.headers[header]
        hash[header] = value if value.present?
      end
    end

    def track_usage(response)
      return unless response.success?

      body = parse_response_body(response.body)
      return unless body.is_a?(Hash) && body["usage"]

      usage = body["usage"]
      TokenUsageTracker.track(
        agent_run: @agent_run,
        tokens_input: usage["input_tokens"] || usage["prompt_tokens"] || 0,
        tokens_output: usage["output_tokens"] || usage["completion_tokens"] || 0
      )
    rescue => e
      log_error("secrets_proxy.track_usage_failed", e.message)
    end

    def parse_response_body(body)
      return body if body.is_a?(Hash)

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def fetch_api_key(provider)
      key = Rails.application.credentials.dig(:llm, :"#{provider}_api_key")
      key ||= ENV["#{provider.to_s.upcase}_API_KEY"]
      raise "Missing API key for #{provider}" unless key

      key
    end

    def log_error(message, error)
      Rails.logger.error(
        message: message,
        agent_run_id: @agent_run&.id,
        error: error
      )
    end
  end
end
