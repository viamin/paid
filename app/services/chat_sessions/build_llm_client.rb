# frozen_string_literal: true

module ChatSessions
  class BuildLlmClient
    ANTHROPIC_SERVICE_TYPE = "anthropic"
    ANTHROPIC_BASE_URL = "https://api.anthropic.com"
    ANTHROPIC_DEFAULT_MODEL = "claude-sonnet-4-20250514"

    def self.call(chat_session:)
      new(chat_session: chat_session).call
    end

    # Default outbound model for a provider service type. Shared with
    # ChatSessions::FallbackRunners so a runner switch picks the same default.
    def self.default_model_for_service_type(service_type)
      return ANTHROPIC_DEFAULT_MODEL if service_type == ANTHROPIC_SERVICE_TYPE

      "gpt-4o"
    end

    def self.usable_runner?(runner)
      runner&.enabled_for_chat? && runner.api_key? && runner.effective_api_secret.present?
    end

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def call
      provider = resolved_runner
      raise LlmClientConfigurationError, missing_runner_message unless provider

      api_key = provider.effective_api_secret
      unless api_key.present?
        raise LlmClientConfigurationError, missing_api_key_message(provider)
      end

      case provider_service_type(provider)
      when ANTHROPIC_SERVICE_TYPE
        anthropic_client(api_key)
      else
        openai_compatible_client(provider, api_key)
      end
    end

    private

    attr_reader :chat_session

    def resolved_runner
      runner = chat_session.runner
      return runner if self.class.usable_runner?(runner)
      return runner if runner.present?

      fallback_runner = Runner.first_configured_chat_enabled_for_owner(chat_session.created_by)
      return runner unless fallback_runner && fallback_runner != runner

      # A runner fallback can also invalidate a provider-specific saved model
      # (for example, Claude -> OpenAI-compatible), so persist the corrected
      # runner/model pair together before building the client.
      chat_session.update!(runner: fallback_runner, model: default_model_for(fallback_runner))
      fallback_runner
    end

    def anthropic_client(api_key)
      model = chat_session.model || ANTHROPIC_DEFAULT_MODEL

      HttpClient.new(
        provider: :anthropic,
        protocol: :messages,
        endpoint: ANTHROPIC_BASE_URL,
        api_key: api_key,
        model: model
      )
    end

    def openai_compatible_client(provider, api_key)
      # @spec CHAT-API-007
      service_type = provider_service_type(provider)
      config = Runner::DIRECT_OUTBOUND_API_PROVIDERS.values.find { |c| c[:service_type] == service_type }
      # @spec CHAT-API-015
      base_url = config&.dig(:chat_base_url) || config&.dig(:base_url) || "https://api.openai.com/v1"
      model = chat_model_for(provider)

      HttpClient.new(
        provider: :openai,
        protocol: :chat_completions,
        endpoint: base_url,
        api_key: api_key,
        model: model,
        max_tokens: config&.dig(:chat_max_tokens),
        model_resolver: provider.free_model_policy? ? -> { chat_model_for(provider) } : nil
      )
    end

    def missing_runner_message
      "Chat requires a configured API-key runner. Add a chat-enabled runner with an API key and select it for this session."
    end

    # @spec CHAT-API-018, MODEL-POLICY-013
    def chat_model_for(runner)
      return chat_session.model || default_model_for(runner) unless runner.free_model_policy?

      model = FreeModels::SelectChatModel.for_session(runner: runner, chat_session: chat_session).model_id
      chat_session.update!(model: model) if chat_session.model != model
      model
    end

    def missing_api_key_message(provider)
      label = provider.name.presence || provider.display_name
      "Chat runner #{label} is missing an API key. Choose a chat-enabled runner with a configured API key."
    end

    def provider_service_type(provider)
      provider.provider_api_key&.api_service_type || provider.required_api_service_type
    end

    def default_model_for(provider)
      return FreeModels::SelectChatModel.for_session(runner: provider, chat_session: chat_session).model_id if provider.free_model_policy?

      provider.direct_outbound_model_id.presence || default_model_for_service_type(provider_service_type(provider))
    end

    def default_model_for_service_type(service_type)
      self.class.default_model_for_service_type(service_type)
    end

    class HttpClient
      # @spec API-CONVERSATION-DELEGATION-001
      ERROR_CLASS_BY_CATEGORY = {
        cancelled: AgentHarness::CancelledError,
        authentication: AgentHarness::AuthenticationError,
        authorization: AgentHarness::AuthorizationError,
        configuration: AgentHarness::ConfigurationError
      }.freeze

      attr_reader :model

      def initialize(provider:, protocol:, endpoint:, api_key:, model:, max_tokens: nil, model_resolver: nil,
        chat_transport: AgentHarness::Api::ChatTransport.new)
        @provider = provider
        @protocol = protocol
        @endpoint = endpoint
        @api_key = api_key
        @model = model
        @max_tokens = max_tokens
        @model_resolver = model_resolver
        @chat_transport = chat_transport
      end

      def call(conversation, tools: nil, on_chunk: nil)
        # @spec CHAT-API-019
        @model = @model_resolver.call if @model_resolver
        request = build_request(conversation, tools, on_chunk.present?)

        result = if on_chunk
          @chat_transport.call(request, &stream_observer(on_chunk))
        else
          @chat_transport.call(request)
        end

        translate_result(result)
      end

      private

      def build_request(conversation, tools, stream)
        {
          operation: :chat,
          request_id: SecureRandom.uuid,
          candidates: [ candidate ],
          messages: format_messages(conversation),
          tools: format_tools(tools),
          max_output_tokens: @max_tokens,
          stream: stream
        }.compact
      end

      def candidate
        {
          provider: @provider,
          model: model,
          protocol: @protocol,
          authentication_mode: :api_key,
          credentials: { api_key: @api_key },
          endpoint: @endpoint
        }
      end

      def stream_observer(on_chunk)
        ->(event) { on_chunk.call(event[:content]) if event[:type] == :text_delta }
      end

      def translate_result(result)
        return raise_classified_error(result[:error]) unless %i[succeeded partial].include?(result[:status])

        {
          content: result[:content].to_s,
          model: result[:model] || model,
          tokens_input: result.dig(:usage, :input_tokens),
          tokens_output: result.dig(:usage, :output_tokens),
          tool_calls: format_inbound_tool_calls(result[:tool_calls])
        }
      end

      def raise_classified_error(error)
        error ||= { message: "Chat request failed" }
        raise rate_limit_error(error) if error[:code] == :rate_limited
        raise AgentHarness::TimeoutError, error[:message] if error[:code] == :timeout

        error_class = ERROR_CLASS_BY_CATEGORY[error[:category]] || AgentHarness::ProviderError
        raise error_class, error[:message]
      end

      def rate_limit_error(error)
        reset_time = error[:retry_after_seconds] ? Time.current + error[:retry_after_seconds] : nil
        AgentHarness::RateLimitError.new(error[:message], reset_time: reset_time)
      end

      def format_messages(conversation)
        system_prompt, remaining_messages = extract_system_prompt(conversation)
        messages = []
        messages << { role: :system, content: system_prompt } if system_prompt.present?

        remaining_messages.each do |message|
          role = message[:role].to_s
          next if role == "system" || skip_message?(message)

          messages << format_message(message, role)
        end

        messages
      end

      def extract_system_prompt(conversation)
        system_messages = conversation.filter_map do |message|
          next unless message[:role].to_s == "system"
          next if message[:content].blank?

          message[:content]
        end

        [ system_messages.presence&.join("\n\n"), conversation ]
      end

      def skip_message?(message)
        message[:content].nil? && message[:tool_calls].blank?
      end

      def format_message(message, role)
        formatted = { role: role.to_sym, content: normalize_content(message[:content], role: role) }
        formatted[:tool_calls] = format_outbound_tool_calls(message[:tool_calls]) if message[:tool_calls].present?
        formatted[:tool_call_id] = message[:tool_call_id] if role == "tool"
        formatted
      end

      def normalize_content(content, role:)
        return JSON.generate(content) if role == "tool" && !content.nil? && !content.is_a?(String)

        content
      end

      # A tool call's provider-assigned id is Paid's single id of record
      # (persisted on `ChatMessage` and round-tripped as `tool_call_id`);
      # setting it as both `id:` and `provider_id:` keeps the harness's
      # separately-generated attempt-scoped id out of Paid's conversation
      # history.
      def format_outbound_tool_calls(tool_calls)
        tool_calls.map do |tool_call|
          id = hash_value(tool_call, :id)
          {
            id: id,
            provider_id: id,
            name: hash_value(tool_call, :name),
            arguments_json: outbound_arguments_json(tool_call)
          }
        end
      end

      def outbound_arguments_json(tool_call)
        arguments = hash_value(tool_call, :arguments)
        arguments.is_a?(String) ? arguments : JSON.generate(arguments || {})
      end

      def format_inbound_tool_calls(tool_calls)
        return nil if tool_calls.blank?

        completed = tool_calls.select { |tool_call| tool_call[:status] == :completed }
        return nil if completed.empty?

        completed.map do |tool_call|
          { id: tool_call[:provider_id] || tool_call[:id], name: tool_call[:name], arguments: tool_call[:arguments_json] }
        end
      end

      def format_tools(definitions)
        return nil if definitions.blank?

        definitions.map do |definition|
          {
            name: hash_value(definition, :name),
            description: hash_value(definition, :description),
            input_schema: hash_value(definition, :inputSchema)
          }
        end
      end

      def hash_value(hash, key)
        hash[key] || hash[key.to_s]
      end
    end
  end
end
