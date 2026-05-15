# frozen_string_literal: true

module Api
  class SecretsProxyController < ActionController::API
    include Api::ContainerAuthentication
    allow_knowledge_run_authentication!
    allow_chat_session_authentication!

    before_action :check_rate_limit

    # Default maximum tokens per agent run before rate limiting kicks in.
    # Canonical value lives on AgentRun::DEFAULT_MAX_TOKENS_PER_RUN;
    # this alias keeps existing references working.
    DEFAULT_MAX_TOKENS_PER_RUN = AgentRun::DEFAULT_MAX_TOKENS_PER_RUN

    # POST /api/proxy/anthropic/*path
    def anthropic
      @api_service_type = :anthropic
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
      @api_service_type = :openai
      api_key = fetch_api_key(:openai)
      return if performed?

      target = resolve_openai_proxy_target

      proxy_request(
        base_url: target.fetch(:base_url),
        path: target.fetch(:path),
        auth_header: "Authorization",
        api_key: "Bearer #{api_key}"
      )
    end

    # POST /api/proxy/google/*path
    def google
      @api_service_type = :google
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

      return unless limit.finite?

      warning_threshold = authenticated_project&.token_limit_warning_threshold
      return unless warning_threshold

      warning_at = (limit * warning_threshold / 100.0).floor
      if current_tokens >= warning_at
        response.set_header("X-Token-Usage", current_tokens.to_s)
        response.set_header("X-Token-Limit", limit.to_s)
        response.set_header("X-Token-Limit-Warning", "true")
      end
    end

    def proxy_request(base_url:, auth_header:, api_key:, path: params[:path] || "")
      target_url = join_target_url(base_url, path)
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

      usage = harness_provider.token_usage_from_api_response(body)
      return if usage.empty?

      model = body["model"] || body["modelVersion"]

      TokenUsageTracker.track(
        tracked_run: @authenticated_run,
        usage: {
          tokens_input: usage[:input_tokens],
          tokens_output: usage[:output_tokens],
          llm_model: model,
          request_type: token_usage_request_type,
          metadata: token_usage_metadata
        }
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
      key = agent_run_api_key(provider)
      return if performed?

      key ||= knowledge_run_api_key(provider)
      return if performed?

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

      runner_entry = agent_run_runner_entry(provider)
      unless runner_entry
        log_error("secrets_proxy.invalid_runner_key", "Runner key is not available for #{provider}")
        render json: { error: "Runner key is not available for this agent run" }, status: :forbidden
        return nil
      end

      runner_entry.provider_api_key.api_key
    end

    def agent_run_runner_entry(provider)
      provider_id = request.headers["X-Paid-Provider-Id"].presence
      return unless provider_id

      runner_entries = @agent_run.project.effective_owner
        &.runners
        &.api_key
        &.joins(:provider_api_key)
      return unless runner_entries

      available_runner_entries(runner_entries)
        .find_by(id: provider_id, provider_api_keys: { api_service_type: provider.to_s })
    end

    def knowledge_run_api_key(provider)
      return unless @knowledge_run

      runner_key = resolved_knowledge_run_runner_key
      return knowledge_run_provider_api_key(provider.to_s) unless runner_key

      config = Runner::DIRECT_OUTBOUND_API_PROVIDERS[runner_key]
      unless config
        log_error("secrets_proxy.invalid_knowledge_runner", "Unknown knowledge runner #{runner_key}")
        render json: { error: "Knowledge runner is not available for this run" }, status: :forbidden
        return nil
      end

      unless compatible_proxy_route?(provider, runner_key)
        log_error("secrets_proxy.invalid_knowledge_runner_route", "Runner #{runner_key} is incompatible with #{provider}")
        render json: { error: "Knowledge runner is not compatible with this proxy route" }, status: :forbidden
        return nil
      end

      key = knowledge_run_provider_api_key(config.fetch(:service_type))
      return key if key.present?

      return nil if runner_key == "openai"

      log_error("secrets_proxy.missing_knowledge_runner_key", "No API key configured for knowledge runner #{runner_key}")
      render json: { error: "API key not configured for knowledge runner #{runner_key}" }, status: :service_unavailable
      nil
    end

    def resolve_openai_proxy_target
      runner_key = resolved_knowledge_run_runner_key
      request_path = (params[:path] || "").sub(%r{\A/+}, "")
      return { base_url: "https://api.openai.com", path: request_path } unless runner_key && @knowledge_run

      config = Runner::DIRECT_OUTBOUND_API_PROVIDERS[runner_key]
      return { base_url: "https://api.openai.com", path: request_path } unless config

      uri = URI.parse(config.fetch(:base_url))
      {
        base_url: "#{uri.scheme}://#{uri.host}#{":#{uri.port}" if uri.port && uri.port != uri.default_port}",
        path: openai_provider_path(uri.path, request_path)
      }
    end

    def resolved_knowledge_run_runner_key
      return unless @knowledge_run

      requested_runner_key = request.headers["X-Paid-Knowledge-Provider"].presence
      return @knowledge_run.final_runner.presence unless requested_runner_key

      return requested_runner_key if allowed_knowledge_run_runner_keys.include?(requested_runner_key)

      log_error("secrets_proxy.invalid_knowledge_runner_selection", "Runner #{requested_runner_key} is not allowed for knowledge run #{@knowledge_run.id}")
      render json: { error: "Knowledge runner is not available for this run" }, status: :forbidden
      nil
    end

    def compatible_proxy_route?(provider, runner_key)
      case provider.to_sym
      when :openai
        Runner::OPENAI_COMPATIBLE_DIRECT_OUTBOUND_API_PROVIDER_KEYS.include?(runner_key)
      when :anthropic
        runner_key == "anthropic"
      else
        false
      end
    end

    def knowledge_run_provider_api_key(service_type)
      @knowledge_run.project.effective_owner
        &.provider_api_keys
        &.for_api_service_type(service_type)
        &.order(created_at: :desc, id: :desc)
        &.first
        &.api_key
    end

    def available_runner_entries(runner_entries)
      runner_entries.for_agent_runs.or(runner_entries.for_fallback)
    end

    def allowed_knowledge_run_runner_keys
      attempted = Array(@knowledge_run.runner_attempts).filter_map do |attempt|
        next attempt.presence unless attempt.is_a?(Hash)

        attempt["runner"].presence || attempt["provider"].presence
      end

      keys = attempted
      keys << @knowledge_run.final_runner if @knowledge_run.final_runner.present?
      keys = keys.compact.uniq
      return keys if keys.any? || @knowledge_run.operation_type != "embedding"

      Knowledge::ProviderConfiguration.for_embedding_candidate_providers(project: @knowledge_run.project).map(&:provider)
    end

    def openai_provider_path(base_path, request_path)
      normalized_base_path = base_path.to_s.sub(%r{/\z}, "")
      normalized_request_path = request_path.to_s.sub(%r{\A/+}, "")
      return normalized_request_path if normalized_base_path.blank?
      return normalized_base_path.delete_prefix("/") if normalized_request_path.blank?

      if normalized_base_path.match?(%r{/v\d+\z}) && normalized_request_path.match?(/\Av\d+(\/.*)?\z/)
        suffix = normalized_request_path.sub(/\Av\d+/, "")
        return "#{normalized_base_path}#{suffix}".delete_prefix("/")
      end

      "#{normalized_base_path}/#{normalized_request_path}".gsub(%r{/+}, "/").delete_prefix("/")
    end

    def join_target_url(base_url, path)
      normalized_base_url = base_url.sub(%r{/+\z}, "")
      normalized_path = path.to_s.sub(%r{\A/+}, "")
      return normalized_base_url if normalized_path.blank?

      "#{normalized_base_url}/#{normalized_path}"
    end

    def resolve_max_tokens_per_run
      return @max_tokens_per_run if defined?(@max_tokens_per_run)
      return @max_tokens_per_run = Float::INFINITY unless @agent_run || @knowledge_run

      authenticated_run.effective_max_tokens_per_run
    end

    def mark_token_limit_exceeded!(current_tokens:, limit:)
      return unless @agent_run || @knowledge_run

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
        chat_session_id: @chat_session&.id,
        current_tokens: current_tokens,
        hard_limit: limit
      )
    end

    def log_error(message, error)
      Rails.logger.error(
        message: message,
        agent_run_id: @agent_run&.id,
        knowledge_run_id: @knowledge_run&.id,
        chat_session_id: @chat_session&.id,
        error: error
      )
    end

    def authenticated_run
      @authenticated_run ||= @chat_session || @knowledge_run || @agent_run
    end

    def authenticated_run_name
      @chat_session ? "chat session" : (@knowledge_run ? "knowledge run" : "agent run")
    end

    def logging_component
      @chat_session ? "chat_execution" : (@knowledge_run ? "knowledge_execution" : "agent_execution")
    end

    def harness_provider
      RunnerSupport.harness_provider_for_api_service_type(@api_service_type)
    end

    def token_usage_request_type
      @chat_session ? "chat" : (@knowledge_run ? "knowledge" : "agent")
    end

    def token_usage_metadata
      return { operation_type: @knowledge_run.operation_type } if @knowledge_run

      {}
    end
  end
end
