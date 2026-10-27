# frozen_string_literal: true

module Llm
  # API protocol selection follows the selected runner's credential and endpoint.
  class ApiRequest
    def self.call(...) = new(...).call

    def initialize(runner:, runtime:, prompt:, timeout:)
      @runner, @runtime, @prompt, @timeout = runner, runtime, prompt, timeout
    end

    def call # @spec LLM-ROUTING-003
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = started + @timeout
      result = AgentHarness::Api::ChatTransport.new.call(
        request_id: SecureRandom.uuid, operation: :chat, candidates: [ candidate ],
        messages: [ { role: :user, content: @prompt } ], tools: [],
        timeout: { read_seconds: @timeout }, retry: { max_attempts: 1 },
        cancellation: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline }
      )
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise AgentHarness::TimeoutError, "Configured API text request timed out"
      end
      raise_transport_error!(result[:error]) if result[:status] != :succeeded && result[:status] != :partial
      succeeded = result[:status] == :succeeded
      usage = result[:usage] || {}
      AgentHarness::Response.new(
        output: result[:content].to_s, exit_code: succeeded ? 0 : 1,
        duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        provider: RunnerSupport.harness_runner_key_for(@runner.runner_key).to_sym,
        model: result[:model].presence || @runtime.model,
        tokens: { input: usage[:input_tokens].to_i, output: usage[:output_tokens].to_i,
                  total: usage[:input_tokens].to_i + usage[:output_tokens].to_i },
        metadata: { transport: :api }, error: succeeded ? nil : "Configured API text request failed"
      )
    end

    private

    def raise_transport_error!(error)
      error ||= {}
      if error[:code] == :rate_limited
        reset_time = Time.current + error[:retry_after_seconds].to_f if error[:retry_after_seconds]
        raise AgentHarness::RateLimitError.new("Configured API text request was rate limited", reset_time: reset_time)
      end
      raise AgentHarness::TimeoutError, "Configured API text request timed out" if error[:code] == :timeout

      error_class = ChatSessions::BuildLlmClient::HttpClient::ERROR_CLASS_BY_CATEGORY[error[:category]] || AgentHarness::ProviderError
      raise error_class, "Configured API text request failed"
    end

    def candidate
      secret = @runner.effective_api_secret
      unless @runner.api_key? && secret.present?
        raise AgentHarness::ConfigurationError, "The configured runner is missing its API credential"
      end

      service = @runner.provider_api_key&.api_service_type || @runner.required_api_service_type
      config = Runner::DIRECT_OUTBOUND_API_PROVIDERS.values.find { |entry| entry[:service_type] == service }
      provider, protocol, endpoint = case service
      when "anthropic"
        [ :anthropic, :messages, ChatSessions::BuildLlmClient::ANTHROPIC_BASE_URL ]
      when "openai"
        [ :openai, :responses, "https://api.openai.com/v1" ]
      when "google"
        [ :openai, :chat_completions, ChatSessions::BuildLlmClient::GOOGLE_OPENAI_BASE_URL ]
      else
        [ :openai, :chat_completions, config&.dig(:chat_base_url) || config&.dig(:base_url) ]
      end
      endpoint = @runtime.base_url.presence || endpoint
      raise AgentHarness::ConfigurationError, "No API text endpoint for the selected runner" if endpoint.blank?

      { provider: provider, protocol: protocol, endpoint: endpoint, model: @runtime.model,
        authentication_mode: :api_key, credentials: { api_key: secret } }
    end
  end
end
