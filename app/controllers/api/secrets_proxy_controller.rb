# frozen_string_literal: true

module Api
  class SecretsProxyController < ActionController::API
    include Api::ContainerAuthentication
    allow_knowledge_run_authentication!

    before_action :check_rate_limit

    # Default maximum tokens per agent run before rate limiting kicks in.
    # Canonical value lives on AgentRun::DEFAULT_MAX_TOKENS_PER_RUN;
    # this alias keeps existing references working.
    DEFAULT_MAX_TOKENS_PER_RUN = AgentRun::DEFAULT_MAX_TOKENS_PER_RUN

    # POST /api/proxy/anthropic/*path
    def anthropic
      api_key = fetch_api_key(:anthropic)
      return if performed?

      proxy_request(
        base_url: "https://api.anthropic.com",
        auth_header: "x-api-key",
        api_key: api_key
      )
    end

    # POST /api/proxy/openai/*path
    def openai
      api_key = fetch_api_key(:openai)
      return if performed?

      proxy_request(
        base_url: "https://api.openai.com",
        auth_header: "Authorization",
        api_key: "Bearer #{api_key}"
      )
    end

    # POST /api/proxy/google/*path
    def google
      api_key = fetch_api_key(:google)
      return if performed?

      proxy_request(
        base_url: "https://generativelanguage.googleapis.com",
        auth_header: "x-goog-api-key",
        api_key: api_key
      )
    end

    private

    def check_rate_limit
      limit = resolve_max_tokens_per_run
      current_tokens = authenticated_run.total_tokens

      if current_tokens >= limit
        mark_token_limit_exceeded!(current_tokens:, limit:)
        render json: {
          error: "Token limit exceeded for this #{authenticated_run_name}",
          token_usage: current_tokens,
          token_limit: limit
        }, status: :too_many_requests
        return
      end

      warning_threshold = authenticated_run.project.token_limit_warning_threshold
      warning_at = (limit * warning_threshold / 100.0).floor
      if current_tokens >= warning_at
        response.set_header("X-Token-Usage", current_tokens.to_s)
        response.set_header("X-Token-Limit", limit.to_s)
        response.set_header("X-Token-Limit-Warning", "true")
      end
    end

    def proxy_request(base_url:, auth_header:, api_key:)
      path = params[:path] || ""
      target_url = "#{base_url}/#{path}"
      target_url = "#{target_url}?#{request.query_string}" if request.query_string.present?

      response = build_connection.run_request(
        request.method.downcase.to_sym,
        target_url,
        request.raw_post,
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
      # Forward essential headers, including provider-specific ones (Anthropic and Google).
      %w[Content-Type Accept anthropic-version anthropic-beta x-goog-api-client].each_with_object({}) do |header, hash|
        value = request.headers[header]
        hash[header] = value if value.present?
      end
    end

    def track_usage(response)
      return unless response.success?

      body = parse_response_body(response.body)
      return unless body.is_a?(Hash)

      input_tokens, output_tokens, model = extract_usage(body)
      return unless input_tokens

      TokenUsageTracker.track(
        agent_run: @agent_run,
        knowledge_run: @knowledge_run,
        usage: {
          tokens_input: input_tokens,
          tokens_output: output_tokens,
          llm_model: model,
          request_type: token_usage_request_type,
          metadata: token_usage_metadata
        }
      )
    rescue => e
      log_error("secrets_proxy.track_usage_failed", e.message)
    end

    # Extracts token counts and model from provider-specific response shapes.
    # Returns [input_tokens, output_tokens, model] or nil if no usage data found.
    def extract_usage(body)
      if body["usage"]
        # Anthropic (input_tokens/output_tokens) and OpenAI (prompt_tokens/completion_tokens)
        usage = body["usage"]
        [
          usage["input_tokens"] || usage["prompt_tokens"] || 0,
          usage["output_tokens"] || usage["completion_tokens"] || 0,
          body["model"]
        ]
      elsif body["usageMetadata"]
        # Google Generative Language API (promptTokenCount/candidatesTokenCount)
        meta = body["usageMetadata"]
        [
          meta["promptTokenCount"] || 0,
          meta["candidatesTokenCount"] || 0,
          body.dig("modelVersion") || body["model"]
        ]
      end
    end

    def parse_response_body(body)
      return body if body.is_a?(Hash)

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def fetch_api_key(provider)
      key = agent_run_api_key(provider)
      return if performed?

      key ||= knowledge_run_api_key(provider)
      key ||= Rails.application.credentials.dig(:llm, :"#{provider}_api_key")
      key ||= ENV["#{provider.to_s.upcase}_API_KEY"]

      unless key
        log_error("secrets_proxy.missing_api_key", "No API key configured for #{provider}")
        render json: { error: "API key not configured for #{provider}" }, status: :service_unavailable
        return nil
      end

      key
    end

    def agent_run_api_key(provider)
      return unless @agent_run
      return unless request.headers["X-Paid-Provider-Id"].present?

      provider_entry = agent_run_provider_entry(provider)
      unless provider_entry
        log_error("secrets_proxy.invalid_provider_key", "Provider key is not available for #{provider}")
        render json: { error: "Provider key is not available for this agent run" }, status: :forbidden
        return nil
      end

      provider_entry.provider_api_key.api_key
    end

    def agent_run_provider_entry(provider)
      provider_id = request.headers["X-Paid-Provider-Id"].presence
      return unless provider_id

      provider_entries = @agent_run.project.effective_owner
        &.providers
        &.api_key
        &.joins(:provider_api_key)
      return unless provider_entries

      available_provider_entries(provider_entries)
        .find_by(id: provider_id, provider_api_keys: { api_service_type: provider.to_s })
    end

    def available_provider_entries(provider_entries)
      provider_entries.for_agent_runs.or(provider_entries.for_fallback)
    end

    def resolve_max_tokens_per_run
      @max_tokens_per_run ||= authenticated_run.effective_max_tokens_per_run
    end

    def mark_token_limit_exceeded!(current_tokens:, limit:)
      status_changed = false

      authenticated_run.with_lock do
        next if authenticated_run.token_limit_status == "exceeded"

        authenticated_run.token_limit_status = "exceeded"
        authenticated_run.save!
        status_changed = true
      end

      return unless status_changed

      if @agent_run
        @agent_run.log!(
          "system",
          "Token limit exceeded: #{current_tokens} of #{limit} tokens used. " \
          "Agent will be stopped after the current operation completes.",
          metadata: { type: "token_limit_exceeded" }
        )
      end

      Rails.logger.warn(
        message: "#{logging_component}.token_limit_exceeded",
        agent_run_id: @agent_run&.id,
        knowledge_run_id: @knowledge_run&.id,
        current_tokens: current_tokens,
        hard_limit: limit
      )
    end

    def log_error(message, error)
      Rails.logger.error(
        message: message,
        agent_run_id: @agent_run&.id,
        knowledge_run_id: @knowledge_run&.id,
        error: error
      )
    end

    def authenticated_run
      @authenticated_run ||= @knowledge_run || @agent_run
    end

    def authenticated_run_name
      @knowledge_run ? "knowledge run" : "agent run"
    end

    def logging_component
      @knowledge_run ? "knowledge_execution" : "agent_execution"
    end

    def knowledge_run_api_key(provider)
      return unless @knowledge_run

      @knowledge_run.project
        .effective_owner
        &.provider_api_keys
        &.for_api_service_type(provider.to_s)
        &.order(created_at: :desc, id: :desc)
        &.first
        &.api_key
    end

    def token_usage_request_type
      @knowledge_run ? "knowledge" : "agent"
    end

    def token_usage_metadata
      return {} unless @knowledge_run

      { operation_type: @knowledge_run.operation_type }
    end
  end
end
