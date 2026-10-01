# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::BuildLlmClient, type: :service do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }

  describe "managed free chat policy" do
    let!(:model) do
      create(:llm_model, :free, model_id: "vendor/chat:free", provider: "openai", catalog_source: "openrouter_sync",
        supports_tools: true, metadata: { "architecture" => { "output_modalities" => [ "text" ] } })
    end
    let(:runner) do
      create(:runner, user: user, runner_key: "opencode", auth_type: "api_key",
        provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
        enabled_for_agent_runs: false, enabled_for_fallback: false,
        config: { "opencode" => { "model_policy" => "free" } })
    end
    let(:session) { create(:chat_session, account: account, created_by: user, runner: runner) }

    # @spec CHAT-API-019
    it "enforces a reference project's provider restrictions" do
      project = create(:project, account: account, model_preferences: { "llm_providers" => { "blocklist" => [ "openai" ] } })
      session.chat_session_projects.create!(project: project, context_type: "reference")

      expect { described_class.call(chat_session: session) }.to raise_error(ChatSessions::LlmClientConfigurationError, /No eligible/)
    end

    # @spec CHAT-API-019
    it "rejects sensitive context attached after the client was built before transmitting a tool round" do
      client = described_class.call(chat_session: session)
      expect(client.model).to eq(model.model_id)
      project = create(:project, account: account, data_classification: "restricted")
      session.chat_session_projects.create!(project: project, context_type: "reference")

      expect { client.call([ { role: "user", content: "Sensitive context" } ]) }
        .to raise_error(ChatSessions::LlmClientConfigurationError, /privacy routing/)
      expect(WebMock).not_to have_requested(:post, "https://openrouter.ai/api/v1/chat/completions")
    end
  end

  # @spec CHAT-API-018, MODEL-POLICY-013
  it "uses the refreshed free chat pool for clients and runner fallbacks instead of a saved paid model" do
    model = create(:llm_model, :free, model_id: "vendor/chat:free", catalog_source: "openrouter_sync",
      supports_tools: true, metadata: { "architecture" => { "output_modalities" => [ "text" ] } })
    runner = create(:runner, user: user, runner_key: "opencode", auth_type: "api_key",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "test-key"),
      enabled_for_agent_runs: false, enabled_for_fallback: false,
      config: { "opencode" => { "model_policy" => "free" } })
    session = create(:chat_session, account: account, created_by: user, runner: runner, model: "gpt-4o")
    request = stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
      .with { |req| JSON.parse(req.body)["model"] == model.model_id }
      .to_return(status: 200, body: { choices: [ { message: { content: "OK" } } ], model: model.model_id }.to_json,
        headers: { "Content-Type" => "application/json" })

    client = described_class.call(chat_session: session)
    expect(client.model).to eq(model.model_id)
    expect(client.call([ { role: "user", content: "Reply OK" } ])[:content]).to eq("OK")
    expect(request).to have_been_requested.once
    ChatSessions::FallbackRunners.switch!(chat_session: session, runner: runner)
    expect(session.reload.model).to eq(model.model_id)

    model.update!(active: false)
    expect { described_class.call(chat_session: session) }.to raise_error(ChatSessions::LlmClientConfigurationError, /No eligible/)
  end

  def build_openai_runner(user:, credential_source:, service_type:, model:, runner_key: "opencode")
    create(:runner,
      user: user,
      runner_key: runner_key,
      auth_type: "api_key",
      provider_api_key: credential_source[:provider_api_key],
      integration_credential: credential_source[:integration_credential],
      config: { runner_key => { "api_provider" => service_type, "model" => model } }
    )
  end

  def stub_chat_transport(client, result: succeeded_result)
    chat_transport = instance_double(AgentHarness::Api::ChatTransport)
    client.instance_variable_set(:@chat_transport, chat_transport)
    allow(chat_transport).to receive(:call).and_return(result)
    chat_transport
  end

  def succeeded_result(content: "Done", model: "gpt-4o")
    { status: :succeeded, content: content, model: model, usage: { input_tokens: 1, output_tokens: 1 }, tool_calls: [] }
  end

  def expect_chat_max_tokens(client, model:, max_tokens:)
    chat_transport = stub_chat_transport(client, result: succeeded_result(model: model))

    client.call([ { role: "user", content: "What did you find?" } ])

    expect(chat_transport).to have_received(:call).with(hash_including(max_output_tokens: max_tokens))
  end

  def expect_chat_without_max_tokens(client, model:)
    chat_transport = stub_chat_transport(client, result: succeeded_result(model: model))

    client.call([ { role: "user", content: "What did you find?" } ])

    expect(chat_transport).to have_received(:call) do |request|
      expect(request).not_to have_key(:max_output_tokens)
    end
  end

  describe ".call" do
    context "with an Anthropic API key runner" do
      it "returns an HttpClient with TextTransport" do
        api_key_record = create(:provider_api_key, user: user, api_key: "sk-ant-test-key", api_service_type: "anthropic")
        runner = create(:runner, :api_key,
          user: user,
          runner_key: "kilocode",
          provider_api_key: api_key_record,
          config: { "kilocode" => { "api_provider" => "anthropic", "model" => "claude-sonnet-4-20250514" } }
        )
        chat_session = create(:chat_session, account: account, created_by: user, runner: runner, model: "claude-sonnet-4-20250514")

        client = described_class.call(chat_session: chat_session)

        expect(client).to be_a(described_class::HttpClient)
        expect(client.model).to eq("claude-sonnet-4-20250514")
      end
    end

    context "with an OpenAI-compatible API key runner" do
      it "returns an HttpClient with OpenAICompatibleTransport" do
        api_key_record = create(:provider_api_key, user: user, api_key: "sk-or-test-key", api_service_type: "openrouter")
        runner = create(:runner, :api_key,
          user: user,
          runner_key: "opencode",
          provider_api_key: api_key_record,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } }
        )
        chat_session = create(:chat_session, account: account, created_by: user, runner: runner, model: "moonshotai/kimi-k2")

        client = described_class.call(chat_session: chat_session)

        expect(client).to be_a(described_class::HttpClient)
        expect(client.model).to eq("moonshotai/kimi-k2")
      end

      it "keeps the transport default output cap for non-z.ai runners" do
        # @spec CHAT-API-007
        api_key_record = create(:provider_api_key, user: user, api_key: "sk-or-test-key", api_service_type: "openrouter")
        runner = build_openai_runner(
          user: user,
          credential_source: { provider_api_key: api_key_record, integration_credential: nil },
          service_type: "openrouter",
          model: "moonshotai/kimi-k2"
        )
        chat_session = create(:chat_session, account: account, created_by: user, runner: runner, model: "moonshotai/kimi-k2")

        client = described_class.call(chat_session: chat_session)
        expect_chat_without_max_tokens(client, model: "moonshotai/kimi-k2")
      end

      it "uses MiniMax's OpenAI chat endpoint for a MiniMax runner" do
        # @spec CHAT-API-015
        api_key_record = create(:provider_api_key, user: user, api_key: "sk-minimax-test-key", api_service_type: "minimax")
        runner = build_openai_runner(
          user: user,
          credential_source: { provider_api_key: api_key_record, integration_credential: nil },
          service_type: "minimax",
          model: "minimax-m3"
        )
        chat_session = create(:chat_session, account: account, created_by: user, runner: runner, model: "minimax-m3")

        client = described_class.call(chat_session: chat_session)
        chat_transport = stub_chat_transport(client, result: succeeded_result(model: "minimax-m3"))

        client.call([ { role: "user", content: "What did you find?" } ])

        expect(chat_transport).to have_received(:call) do |request|
          expect(request[:candidates].first[:endpoint]).to eq("https://api.minimax.io/v1")
        end
      end

      %w[zai zai_coding].each do |service_type|
        it "raises the z.ai chat output cap above the transport default for #{service_type} runners" do
          # @spec CHAT-API-007
          api_key_record = create(:provider_api_key, user: user, api_key: "sk-zai-test-key", api_service_type: service_type)
          runner = build_openai_runner(
            user: user,
            credential_source: { provider_api_key: api_key_record, integration_credential: nil },
            service_type: service_type,
            model: "glm-5.3"
          )
          chat_session = create(:chat_session, account: account, created_by: user, runner: runner, model: "glm-5.3")

          client = described_class.call(chat_session: chat_session)
          expect_chat_max_tokens(client, model: "glm-5.3", max_tokens: 16_384)
        end
      end

      %w[zai zai_coding].each do |service_type|
        it "uses the runner service type when an OpenAI-compatible #{service_type} runner is backed by an integration credential" do
          # @spec CHAT-API-007
          integration_credential = create(:integration_credential,
            account: account,
            created_by: user,
            service_key: "opencode",
            secret: "sk-integration-test-key"
          )
          runner = build_openai_runner(
            user: user,
            credential_source: { provider_api_key: nil, integration_credential: integration_credential },
            service_type: service_type,
            model: "glm-5.3"
          )
          chat_session = create(:chat_session, account: account, created_by: user, runner: runner, model: "glm-5.3")

          client = described_class.call(chat_session: chat_session)
          expect_chat_max_tokens(client, model: "glm-5.3", max_tokens: 16_384)
        end
      end
    end

    context "with an integration credential-backed API key runner" do
      it "returns an HttpClient using the runner's effective secret" do
        integration_credential = create(:integration_credential,
          account: account,
          created_by: user,
          service_key: "claude",
          secret: "sk-integration-test-key"
        )
        runner = create(:runner,
          user: user,
          runner_key: "claude",
          auth_type: "api_key",
          provider_api_key: nil,
          integration_credential: integration_credential
        )
        chat_session = create(:chat_session, account: account, created_by: user, runner: runner, model: "claude-3-7-sonnet")

        client = described_class.call(chat_session: chat_session)

        expect(client).to be_a(described_class::HttpClient)
        expect(client.model).to eq("claude-3-7-sonnet")
      end
    end

    context "with a subscription runner (no API key)" do
      it "raises a setup error for the selected runner" do
        runner = user.runners.find_or_create_by!(runner_key: "cursor", auth_type: "subscription")
        chat_session = create(:chat_session, account: account, created_by: user, runner: runner)

        expect {
          described_class.call(chat_session: chat_session)
        }.to raise_error(
          ChatSessions::LlmClientConfigurationError,
          "Chat runner #{runner.display_name} is missing an API key. Choose a chat-enabled runner with a configured API key."
        )
      end
    end

    context "without a runner but with a configured fallback" do
      it "falls back to the creator's configured API key runner" do
        chat_session = create(:chat_session, account: account, created_by: user)
        api_key_record = create(:provider_api_key, user: user, api_key: "sk-or-fallback", api_service_type: "openrouter")
        fallback_runner = create(:runner, :api_key,
          user: user,
          runner_key: "opencode",
          provider_api_key: api_key_record,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } }
        )

        client = described_class.call(chat_session: chat_session)

        expect(client).to be_a(described_class::HttpClient)
        expect(chat_session.reload.runner).to eq(fallback_runner)
        expect(chat_session.model).to eq("moonshotai/kimi-k2")
        expect(client.model).to eq("moonshotai/kimi-k2")
      end
    end

    context "with an API key runner missing its secret" do
      it "raises a setup error for the selected runner" do
        api_key_record = create(:provider_api_key, user: user, api_key: "sk-ant-test-key", api_service_type: "anthropic")
        runner = create(:runner, :api_key,
          user: user,
          runner_key: "kilocode",
          provider_api_key: api_key_record,
          config: { "kilocode" => { "api_provider" => "anthropic", "model" => "claude-sonnet-4-20250514" } }
        )
        chat_session = create(:chat_session, account: account, created_by: user, runner: runner)
        allow(runner).to receive(:effective_api_secret).and_return(nil)

        expect {
          described_class.call(chat_session: chat_session)
        }.to raise_error(
          ChatSessions::LlmClientConfigurationError,
          "Chat runner #{runner.display_name} is missing an API key. Choose a chat-enabled runner with a configured API key."
        )
      end
    end

    context "with an unconfigured runner and another configured chat runner" do
      it "raises a setup error for the selected runner" do
        unavailable_runner = user.runners.find_or_create_by!(runner_key: "claude", auth_type: "subscription")
        chat_session = create(:chat_session,
          account: account,
          created_by: user,
          runner: unavailable_runner,
          model: "claude-sonnet-4-20250514"
        )

        expect {
          described_class.call(chat_session: chat_session)
        }.to raise_error(ChatSessions::LlmClientConfigurationError)
      end
    end

    context "without a runner and without a configured fallback" do
      it "raises a setup error" do
        chat_session = create(:chat_session, account: account, created_by: user)

        expect {
          described_class.call(chat_session: chat_session)
        }.to raise_error(
          ChatSessions::LlmClientConfigurationError,
          "Chat requires a configured API-key runner. Add a chat-enabled runner with an API key and select it for this session."
        )
      end
    end
  end

  # @spec API-CONVERSATION-DELEGATION-001
  describe described_class::HttpClient do
    let(:tool_definitions) do
      [
        {
          name: "search",
          description: "Search the project",
          inputSchema: {
            type: "object",
            properties: {
              query: { type: "string" }
            },
            required: [ "query" ]
          }
        }
      ]
    end

    let(:chat_transport) { instance_double(AgentHarness::Api::ChatTransport) }
    let(:model) { "claude-sonnet-4-20250514" }
    let(:client) do
      described_class.new(provider: :anthropic, protocol: :messages, endpoint: ChatSessions::BuildLlmClient::ANTHROPIC_BASE_URL,
        api_key: "sk-ant-test", model: model, chat_transport: chat_transport)
    end
    let(:conversation) do
      [
        { role: "system", content: "You are helpful." },
        { role: "user", content: "Find the issue" },
        {
          role: "assistant",
          content: "Let me search.",
          tool_calls: [ { id: "toolu_1", name: "search", arguments: { query: "issue" } } ]
        },
        { role: "tool", content: '{"results":[]}', tool_call_id: "toolu_1", tool_name: "search" },
        { role: "user", content: "What did you find?" }
      ]
    end
    let(:expected_messages) do
      [
        { role: :system, content: "You are helpful." },
        { role: :user, content: "Find the issue" },
        {
          role: :assistant,
          content: "Let me search.",
          tool_calls: [ { id: "toolu_1", provider_id: "toolu_1", name: "search", arguments_json: '{"query":"issue"}' } ]
        },
        { role: :tool, content: '{"results":[]}', tool_call_id: "toolu_1" },
        { role: :user, content: "What did you find?" }
      ]
    end
    let(:expected_tools) do
      [
        {
          name: "search",
          description: "Search the project",
          input_schema: tool_definitions.first[:inputSchema]
        }
      ]
    end
    let(:succeeded_result) do
      {
        status: :succeeded,
        content: "I'm doing well!",
        model: "claude-sonnet-4-20250514",
        usage: { input_tokens: 20, output_tokens: 10 },
        tool_calls: []
      }
    end

    it "passes a single-candidate normalized request and translates the result" do
      allow(chat_transport).to receive(:call).and_return(succeeded_result)

      result = client.call(conversation, tools: tool_definitions)

      expect(chat_transport).to have_received(:call) do |request|
        expect(request[:operation]).to eq(:chat)
        expect(request[:messages]).to eq(expected_messages)
        expect(request[:tools]).to eq(expected_tools)
        expect(request[:stream]).to be(false)
        expect(request[:candidates]).to eq([
          {
            provider: :anthropic, model: model, protocol: :messages, authentication_mode: :api_key,
            credentials: { api_key: "sk-ant-test" }, endpoint: ChatSessions::BuildLlmClient::ANTHROPIC_BASE_URL
          }
        ])
      end

      expect(result[:content]).to eq("I'm doing well!")
      expect(result[:model]).to eq("claude-sonnet-4-20250514")
      expect(result[:tokens_input]).to eq(20)
      expect(result[:tokens_output]).to eq(10)
    end

    it "folds later system messages into a single leading system message" do
      allow(chat_transport).to receive(:call).and_return(succeeded_result)

      client.call([
        { role: "system", content: "You are helpful." },
        { role: "user", content: "Find the issue" },
        { role: "system", content: "## Added Project Context: Paid" },
        { role: "user", content: "What did you find?" }
      ])

      expect(chat_transport).to have_received(:call).with(
        hash_including(
          messages: [
            { role: :system, content: "You are helpful.\n\n## Added Project Context: Paid" },
            { role: :user, content: "Find the issue" },
            { role: :user, content: "What did you find?" }
          ]
        )
      )
    end

    it "streams text_delta events through the on_chunk callback" do
      chunks_received = []
      allow(chat_transport).to receive(:call) do |_request, &observer|
        observer.call(type: :response_started)
        observer.call(type: :text_delta, content: "Hello")
        observer.call(type: :text_delta, content: " world")
        observer.call(type: :response_completed, result: succeeded_result)
        succeeded_result
      end

      client.call(conversation, on_chunk: ->(chunk) { chunks_received << chunk })

      expect(chunks_received).to eq([ "Hello", " world" ])
    end

    it "returns already-streamed content as a successful turn when the provider connection drops mid-stream" do
      chunks_received = []
      partial_result = {
        status: :partial,
        content: "Partial ans",
        model: "claude-sonnet-4-20250514",
        usage: { input_tokens: 12, output_tokens: 3 },
        tool_calls: [],
        error: { category: :transient, code: :service_unavailable, retryable: false, message: "unavailable" }
      }
      allow(chat_transport).to receive(:call) do |_request, &observer|
        observer.call(type: :text_delta, content: "Partial ")
        observer.call(type: :text_delta, content: "ans")
        observer.call(type: :response_failed, result: partial_result)
        partial_result
      end

      result = client.call(conversation, on_chunk: ->(chunk) { chunks_received << chunk })

      expect(chunks_received).to eq([ "Partial ", "ans" ])
      expect(result[:content]).to eq("Partial ans")
      expect(result[:tool_calls]).to be_nil
    end

    it "omits tools when none are defined" do
      allow(chat_transport).to receive(:call).and_return(succeeded_result)

      client.call(conversation, tools: [])

      expect(chat_transport).to have_received(:call) do |request|
        expect(request).not_to have_key(:tools)
      end
    end

    it "translates completed tool calls back to the provider id used in Paid's history" do
      tool_result = succeeded_result.merge(
        content: "Let me search.",
        tool_calls: [
          { id: "harness-generated-id", provider_id: "tc_1", name: "search", arguments_json: '{"q":"test"}', status: :completed },
          { id: "harness-generated-id-2", provider_id: "tc_2", name: "search", arguments_json: "{}", status: :incomplete }
        ]
      )
      allow(chat_transport).to receive(:call).and_return(tool_result)

      result = client.call(conversation)

      expect(result[:tool_calls]).to eq([ { id: "tc_1", name: "search", arguments: '{"q":"test"}' } ])
    end

    it "raises AgentHarness::RateLimitError with a computed reset_time for a rate-limited failure" do
      allow(Time).to receive(:current).and_return(Time.utc(2026, 1, 1, 12, 0, 0))
      failed_result = {
        status: :failed,
        error: { category: :transient, code: :rate_limited, retryable: true, message: "rate limited", retry_after_seconds: 30 }
      }
      allow(chat_transport).to receive(:call).and_return(failed_result)

      expect { client.call(conversation) }.to raise_error(AgentHarness::RateLimitError) do |error|
        expect(error.reset_time).to eq(Time.utc(2026, 1, 1, 12, 0, 30))
      end
    end

    it "raises AgentHarness::AuthenticationError for an authentication failure without entering rate-limit retry" do
      failed_result = {
        status: :failed,
        error: { category: :authentication, code: :invalid_credential, retryable: false, message: "invalid key" }
      }
      allow(chat_transport).to receive(:call).and_return(failed_result)

      expect { client.call(conversation) }.to raise_error(AgentHarness::AuthenticationError, "invalid key")
    end

    it "raises AgentHarness::ProviderError for an unmapped category" do
      failed_result = {
        status: :failed,
        error: { category: :unknown, code: :unclassified_provider_error, retryable: false, message: "boom" }
      }
      allow(chat_transport).to receive(:call).and_return(failed_result)

      expect { client.call(conversation) }.to raise_error(AgentHarness::ProviderError, "boom")
    end

    context "with an OpenAI-compatible candidate" do
      let(:client) do
        described_class.new(provider: :openai, protocol: :chat_completions, endpoint: "https://api.openai.com/v1",
          api_key: "sk-openai-test", model: "gpt-4o", chat_transport: chat_transport)
      end

      it "passes configured max_tokens as max_output_tokens" do
        client = described_class.new(provider: :openai, protocol: :chat_completions, endpoint: "https://api.z.ai/api/paas/v4",
          api_key: "sk-zai-test", model: "glm-5.3", max_tokens: 16_384, chat_transport: chat_transport)
        allow(chat_transport).to receive(:call).and_return(succeeded_result)

        client.call(conversation)

        expect(chat_transport).to have_received(:call).with(hash_including(max_output_tokens: 16_384))
      end

      it "builds an openai-provider candidate with chat_completions protocol" do
        allow(chat_transport).to receive(:call).and_return(succeeded_result)

        client.call(conversation)

        expect(chat_transport).to have_received(:call) do |request|
          expect(request[:candidates].first).to include(provider: :openai, protocol: :chat_completions,
            endpoint: "https://api.openai.com/v1")
        end
      end
    end
  end
end
