# frozen_string_literal: true

module ChatSessions
  class BuildLlmClient
    ANTHROPIC_SERVICE_TYPE = "anthropic"
    ANTHROPIC_BASE_URL = "https://api.anthropic.com"
    GOOGLE_SERVICE_TYPE = "google"
    GOOGLE_OPENAI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/openai"

    def self.call(chat_session:, actor: chat_session.created_by, message: nil)
      new(chat_session: chat_session, actor: actor, message: message).call
    end

    def self.usable_runner?(runner)
      runner&.enabled_for_chat? && runner.api_key? && runner.effective_api_secret.present?
    end

    def initialize(chat_session:, actor: chat_session.created_by, message: nil)
      @chat_session = chat_session
      @actor = actor
      @message = message
    end

    def call
      provider = resolved_runner
      raise LlmClientConfigurationError, missing_runner_message unless provider

      api_key = provider.effective_api_secret
      unless api_key.present?
        raise LlmClientConfigurationError, missing_api_key_message(provider)
      end
      ensure_api_chat_privacy_supported!(provider)

      case provider_service_type(provider)
      when ANTHROPIC_SERVICE_TYPE
        anthropic_client(api_key)
      else
        openai_compatible_client(provider, api_key)
      end
    end

    private

    attr_reader :chat_session, :actor, :message

    def resolved_runner
      runner = chat_session.runner
      return runner if self.class.usable_runner?(runner)
      return runner if runner.present?

      fallback_runner = Runner.first_configured_chat_enabled_for_owner(chat_session.created_by)
      return runner unless fallback_runner && fallback_runner != runner

      # A runner fallback can also invalidate a provider-specific saved model
      # (for example, Claude -> OpenAI-compatible), so persist the corrected
      # runner/model pair together before building the client.
      persist_curated_model!(fallback_runner)
      fallback_runner
    end

    def anthropic_client(api_key)
      model = chat_session.model || persist_curated_model!(resolved_runner)

      HttpClient.new(
        chat_session: chat_session,
        provider: :anthropic,
        protocol: :messages,
        endpoint: ANTHROPIC_BASE_URL,
        api_key: api_key,
        model: model,
        reasoning_effort: effective_thinking_effort(model),
        actor: actor,
        message: message
      )
    end

    def openai_compatible_client(provider, api_key)
      # @spec CHAT-API-007
      service_type = provider_service_type(provider)
      config = Runner::DIRECT_OUTBOUND_API_PROVIDERS.values.find { |c| c[:service_type] == service_type }
      # @spec CHAT-API-015
      base_url = config&.dig(:chat_base_url) || config&.dig(:base_url) || default_openai_base_url(service_type)
      model = chat_model_for(provider)

      HttpClient.new(
        chat_session: chat_session,
        provider: :openai,
        protocol: openai_protocol_for(service_type),
        endpoint: base_url,
        api_key: api_key,
        model: model,
        max_tokens: config&.dig(:chat_max_tokens),
        model_resolver: provider.free_model_policy? ? -> { chat_model_for(provider) } : nil,
        # Free-policy runners have no saved curated model choice (the pool
        # rotates per request), so there is no stable model to validate a
        # thinking-effort preference against either.
        reasoning_effort: provider.free_model_policy? ? nil : effective_thinking_effort(model),
        actor: actor,
        message: message
      )
    end

    # @spec CHAT-THINKING-EFFORT-007
    def effective_thinking_effort(model_id)
      ThinkingEffort.normalize(model_id: model_id, value: chat_session.metadata["thinking_effort"])
    end

    # @spec API-CONVERSATION-DELEGATION-007
    def openai_protocol_for(service_type)
      service_type == "openai" ? :responses : :chat_completions
    end

    def missing_runner_message
      "Chat requires a configured API-key runner. Add a chat-enabled runner with an API key and select it for this session."
    end

    # @spec CHAT-API-018, MODEL-POLICY-013
    def chat_model_for(runner)
      return chat_session.model || persist_curated_model!(runner) unless runner.free_model_policy?

      model = FreeModels::SelectChatModel.for_session(runner: runner, chat_session: chat_session).model_id
      if chat_session.model != model
        metadata = ThinkingEffort.normalize_metadata(metadata: chat_session.metadata, model_id: model)
        chat_session.update!(model: model, metadata: metadata)
      end
      model
    end

    def missing_api_key_message(provider)
      label = provider.name.presence || provider.display_name
      "Chat runner #{label} is missing an API key. Choose a chat-enabled runner with a configured API key."
    end

    def provider_service_type(provider)
      provider.provider_api_key&.api_service_type || provider.required_api_service_type
    end

    # agent-harness 0.44.22's API ChatTransport has no provider-routing
    # candidate contract. Block an OpenRouter ZDR request rather than sending
    # a prompt with metadata the transport cannot consume.
    # @spec MODEL-POLICY-019
    def ensure_api_chat_privacy_supported!(provider)
      project = chat_session.llm_policy_projects.find(&:restricted?)
      policy = provider.effective_privacy_policy(project: project)
      return unless policy.zdr_required

      if provider.required_api_service_type == Runner::OPENROUTER_FREE_MODEL_PROVIDER
        raise LlmClientConfigurationError,
          "This chat transport cannot enforce the required OpenRouter zero data retention policy. Use container chat or choose a user-declared ZDR provider."
      end
      return if policy.eligible

      raise LlmClientConfigurationError,
        "The selected chat runner cannot satisfy the required zero data retention policy without an explicit ZDR declaration."
    end

    def persist_curated_model!(runner)
      # @spec CHAT-API-026
      option = CuratedModelOptions.resolve(runner:, projects: chat_session.llm_policy_projects)
      unless option
        raise LlmClientConfigurationError,
          "No compatible Low chat model is available for #{runner.display_name}. Check the catalog, API availability, and operator policy."
      end

      # @spec CHAT-THINKING-EFFORT-007
      metadata = ThinkingEffort.normalize_metadata(
        metadata: chat_session.metadata.merge("model_tier" => option.tier),
        model_id: option.model_id
      )
      chat_session.update!(runner:, model: option.model_id, metadata: metadata)
      option.model_id
    end

    def default_openai_base_url(service_type)
      return GOOGLE_OPENAI_BASE_URL if service_type == GOOGLE_SERVICE_TYPE

      "https://api.openai.com/v1"
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

      # Reasoning effort stays deferred until agent-harness publishes both a
      # capability declaration and the matching candidate/request contract.
      # Verified during #4589 review: 0.44.22 is the newest published
      # release (rubygems.org; `bin/update --check` reports the gem pin up
      # to date), and its ChatTransport declares neither the capability
      # predicate nor a candidate/request effort field — no dependency
      # version exists yet that could carry the value to a provider, so the
      # pin cannot be updated in this PR. Fail-closed here hides the
      # selector and drops the parameter until a contract-carrying release
      # is installable; the #4475 tracking issue stays open until that pin
      # bump is verified end to end.
      # @spec CHAT-THINKING-EFFORT-008
      def self.reasoning_effort_transport_supported?
        AgentHarness::Api::ChatTransport.respond_to?(:reasoning_effort_transport_supported?) &&
          AgentHarness::Api::ChatTransport.reasoning_effort_transport_supported?
      end

      def initialize(chat_session:, provider:, protocol:, endpoint:, api_key:, model:, max_tokens: nil, model_resolver: nil,
        reasoning_effort: nil, chat_transport: AgentHarness::Api::ChatTransport.new, actor: nil, message: nil)
        @chat_session = chat_session
        @provider = provider
        @protocol = protocol
        @endpoint = endpoint
        @api_key = api_key
        @model = model
        @max_tokens = max_tokens
        @model_resolver = model_resolver
        @reasoning_effort = reasoning_effort
        @actor = actor
        @message = message
        @harness_transport = HarnessTransport.new(chat_session: chat_session, transport: chat_transport)
      end

      def call(conversation, tools: nil, on_chunk: nil)
        # @spec CHAT-API-019
        @model = @model_resolver.call if @model_resolver
        request = build_request(conversation, tools, on_chunk.present?)

        result = if on_chunk
          @harness_transport.call(request, &stream_observer(on_chunk))
        else
          @harness_transport.call(request)
        end

        persist_attempts(result)
        translate_result(result)
      end

      private

      # @spec API-CONVERSATION-DELEGATION-002
      def persist_attempts(result)
        return if @message.nil? || result[:attempts].blank?

        result[:attempts].each do |report|
          ChatSessions::RecordTransportAttempt.call(
            chat_session: @chat_session,
            actor: @actor,
            message: @message,
            report: annotate_with_reasoning_effort(report)
          )
        end
      end

      # @spec CHAT-THINKING-EFFORT-008
      def annotate_with_reasoning_effort(report)
        return report unless self.class.reasoning_effort_transport_supported? && @reasoning_effort

        report.merge(reasoning_effort: @reasoning_effort)
      end

      def build_request(conversation, tools, stream)
        {
          operation: :chat,
          candidates: [ candidate ],
          messages: format_messages(conversation),
          tools: format_tools(tools),
          max_output_tokens: @max_tokens,
          stream: stream
        }.compact
      end

      def candidate
        base = {
          provider: @provider,
          model: model,
          protocol: @protocol,
          authentication_mode: :api_key,
          credentials: { api_key: @api_key },
          endpoint: @endpoint
        }
        return base unless self.class.reasoning_effort_transport_supported? && @reasoning_effort

        base.merge(reasoning_effort: @reasoning_effort)
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
          tool_calls: format_inbound_tool_calls(result[:tool_calls]),
          provider_state: result[:provider_state]
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
