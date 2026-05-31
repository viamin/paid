# frozen_string_literal: true

module ChatSessions
  class BuildLlmClient
    ANTHROPIC_SERVICE_TYPE = "anthropic"

    def self.call(chat_session:)
      new(chat_session: chat_session).call
    end

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def call
      provider = chat_session.runner
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

    def anthropic_client(api_key)
      transport = AgentHarness::TextTransport.new(api_key: api_key)
      model = chat_session.model || AgentHarness::TextTransport::DEFAULT_MODEL
      HttpClient.new(transport: transport, model: model, provider_type: :anthropic)
    end

    def openai_compatible_client(provider, api_key)
      service_type = provider_service_type(provider)
      config = Runner::DIRECT_OUTBOUND_API_PROVIDERS.values.find { |c| c[:service_type] == service_type }
      base_url = config&.dig(:base_url) || "https://api.openai.com/v1"
      model = chat_session.model || "gpt-4o"

      transport = AgentHarness::OpenAICompatibleTransport.new(
        base_url: base_url,
        api_key: api_key,
        model: model
      )

      HttpClient.new(transport: transport, model: model, provider_type: :openai_compatible)
    end

    def missing_runner_message
      "Chat requires a configured API-key runner. Add a chat-enabled runner with an API key and select it for this session."
    end

    def missing_api_key_message(provider)
      label = provider.name.presence || provider.display_name
      "Chat runner #{label} is missing an API key. Choose a chat-enabled runner with a configured API key."
    end

    def provider_service_type(provider)
      provider.provider_api_key&.api_service_type || provider.required_api_service_type
    end

    class HttpClient
      attr_reader :model

      def initialize(transport:, model:, provider_type:)
        @transport = transport
        @model = model
        @provider_type = provider_type
      end

      def call(conversation, on_chunk: nil)
        messages = format_messages(conversation)

        stream_callback = build_stream_callback(on_chunk) if on_chunk

        response = if stream_callback
          @transport.chat(messages: messages, model: model, stream: true, &stream_callback)
        else
          @transport.chat(messages: messages, model: model, stream: false)
        end

        {
          content: response.output,
          model: response.model,
          tokens_input: response.input_tokens,
          tokens_output: response.output_tokens,
          tool_calls: response.metadata[:tool_calls]
        }
      end

      private

      def build_stream_callback(on_chunk)
        proc { |event| on_chunk.call(event[:content]) if event[:type] == :text }
      end

      def format_messages(conversation)
        conversation.filter_map do |msg|
          content = msg[:content]
          next nil if content.nil?

          entry = { role: msg[:role].to_s, content: content }
          entry[:tool_call_id] = msg[:tool_call_id].to_s if msg[:tool_call_id].present?
          entry[:tool_name] = msg[:tool_name].to_s if msg[:tool_name].present?
          entry
        end
      end
    end
  end
end
