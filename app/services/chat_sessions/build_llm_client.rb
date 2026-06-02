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
      return runner if runner&.effective_api_secret.present?

      fallback_runner = Runner.first_configured_chat_enabled_for_owner(chat_session.created_by)
      return runner unless fallback_runner && fallback_runner != runner

      # A runner fallback can also invalidate a provider-specific saved model
      # (for example, Claude -> OpenAI-compatible), so persist the corrected
      # runner/model pair together before building the client.
      chat_session.update!(runner: fallback_runner, model: default_model_for(fallback_runner))
      fallback_runner
    end

    def anthropic_client(api_key)
      transport = AgentHarness::TextTransport.new(api_key: api_key)
      model = chat_session.model || AgentHarness::TextTransport::DEFAULT_MODEL
      HttpClient.new(transport: transport, model: model, provider_type: :anthropic)
    end

    def openai_compatible_client(provider, api_key)
      service_type = provider_service_type(provider)
      config = Runner::DIRECT_OUTBOUND_API_PROVIDERS.values.find { |c| c[:service_type] == service_type }
      base_url = config&.dig(:base_url) || "https://api.openai.com/v1"
      model = chat_session.model || default_model_for(provider)

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

    def default_model_for(provider)
      provider.direct_outbound_model_id.presence || default_model_for_service_type(provider_service_type(provider))
    end

    def default_model_for_service_type(service_type)
      return AgentHarness::TextTransport::DEFAULT_MODEL if service_type == ANTHROPIC_SERVICE_TYPE

      "gpt-4o"
    end

    class HttpClient
      attr_reader :model

      def initialize(transport:, model:, provider_type:)
        @transport = transport
        @model = model
        @provider_type = provider_type
      end

      def call(conversation, tools: nil, on_chunk: nil)
        messages = format_messages(conversation)
        formatted_tools = format_tools(tools)

        stream_callback = build_stream_callback(on_chunk) if on_chunk

        response = if stream_callback
          @transport.chat(messages: messages, model: model, tools: formatted_tools, stream: true, &stream_callback)
        else
          @transport.chat(messages: messages, model: model, tools: formatted_tools, stream: false)
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
        conversation_object = build_conversation_object(conversation)
        return conversation_object.to_openai_messages if @provider_type == :openai_compatible

        anthropic_messages(conversation_object)
      end

      def build_conversation_object(conversation)
        system_prompt, remaining_messages = extract_system_prompt(conversation)
        AgentHarness::Conversation.new(system_prompt: system_prompt).tap do |conversation_object|
          remaining_messages.each do |message|
            next if skip_message?(message)

            normalized = normalize_content(message[:content], role: message[:role])
            conversation_object.add_message(
              message[:role],
              normalized,
              tool_calls: message[:tool_calls],
              tool_call_id: message[:tool_call_id],
              tool_name: message[:tool_name],
              tool_result: normalized
            )
          end
        end
      end

      def anthropic_messages(conversation_object)
        formatted = conversation_object.to_anthropic_messages
        return formatted[:messages] unless formatted[:system].present?

        [ { role: "system", content: formatted[:system] } ] + formatted[:messages]
      end

      def extract_system_prompt(conversation)
        first_message = conversation.first
        return [ nil, conversation ] unless first_message && first_message[:role].to_s == "system"

        [ first_message[:content], conversation.drop(1) ]
      end

      def skip_message?(message)
        message[:content].nil? && message[:tool_calls].blank?
      end

      def normalize_content(content, role:)
        return JSON.generate(content) if role.to_s == "tool" && !content.nil? && !content.is_a?(String)

        content
      end

      def format_tools(definitions)
        return nil if definitions.blank?

        definitions.map do |definition|
          if @provider_type == :anthropic
            {
              name: hash_value(definition, :name),
              description: hash_value(definition, :description),
              input_schema: hash_value(definition, :inputSchema)
            }
          else
            {
              type: "function",
              function: {
                name: hash_value(definition, :name),
                description: hash_value(definition, :description),
                parameters: hash_value(definition, :inputSchema)
              }
            }
          end
        end
      end

      def hash_value(hash, key)
        hash[key] || hash[key.to_s]
      end
    end
  end
end
