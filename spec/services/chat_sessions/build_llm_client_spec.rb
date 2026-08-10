# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::BuildLlmClient, type: :service do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }

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

    let(:response) do
      instance_double(AgentHarness::Response,
        output: "I'm doing well!",
        model: "claude-sonnet-4-20250514",
        input_tokens: 20,
        output_tokens: 10,
        metadata: {}
      )
    end

    context "with an Anthropic transport" do
      let(:transport) { instance_double(AgentHarness::TextTransport) }
      let(:model) { "claude-sonnet-4-20250514" }
      let(:client) { described_class.new(transport: transport, model: model, provider_type: :anthropic) }
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
          { role: "system", content: "You are helpful." },
          { role: "user", content: [ { type: "text", text: "Find the issue" } ] },
          {
            role: "assistant",
            content: [
              { type: "text", text: "Let me search." },
              { type: "tool_use", id: "toolu_1", name: "search", input: { query: "issue" } }
            ]
          },
          {
            role: "user",
            content: [ { type: "tool_result", tool_use_id: "toolu_1", content: '{"results":[]}' } ]
          },
          { role: "user", content: [ { type: "text", text: "What did you find?" } ] }
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

      it "passes anthropic-formatted messages and tools to the transport" do
        allow(transport).to receive(:chat).and_return(response)

        result = client.call(conversation, tools: tool_definitions)

        expect(transport).to have_received(:chat) do |**kwargs|
          expect(kwargs[:messages]).to eq(expected_messages)
          expect(kwargs[:tools]).to eq(expected_tools)
          expect(kwargs[:model]).to eq(model)
          expect(kwargs[:stream]).to be(false)
        end

        expect(result[:content]).to eq("I'm doing well!")
        expect(result[:model]).to eq("claude-sonnet-4-20250514")
        expect(result[:tokens_input]).to eq(20)
        expect(result[:tokens_output]).to eq(10)
      end

      it "folds later system messages into the system prompt" do
        allow(transport).to receive(:chat).and_return(response)

        client.call([
          { role: "system", content: "You are helpful." },
          { role: "user", content: "Find the issue" },
          { role: "system", content: "## Added Project Context: Paid" },
          { role: "user", content: "What did you find?" }
        ])

        expect(transport).to have_received(:chat).with(
          hash_including(
            messages: [
              { role: "system", content: "You are helpful.\n\n## Added Project Context: Paid" },
              { role: "user", content: [ { type: "text", text: "Find the issue" } ] },
              { role: "user", content: [ { type: "text", text: "What did you find?" } ] }
            ]
          )
        )
      end

      it "streams text chunks through on_chunk callback" do
        chunks_received = []

        allow(transport).to receive(:chat) do |**_opts, &block|
          block.call({ type: :text, content: "Hello" })
          block.call({ type: :text, content: " world" })
          block.call({ type: :usage, input_tokens: 10, output_tokens: 5 })
          block.call({ type: :done })
          response
        end

        client.call(conversation, on_chunk: ->(chunk) { chunks_received << chunk })

        expect(chunks_received).to eq([ "Hello", " world" ])
      end

      it "returns nil tools when none are defined" do
        allow(transport).to receive(:chat).and_return(response)

        client.call(conversation, tools: [])

        expect(transport).to have_received(:chat).with(hash_including(tools: nil))
      end

      it "passes tool_calls from response metadata" do
        tool_response = instance_double(AgentHarness::Response,
          output: "Let me search.",
          model: "claude-sonnet-4-20250514",
          input_tokens: 15,
          output_tokens: 5,
          metadata: { tool_calls: [ { id: "tc_1", name: "search", arguments: '{"q":"test"}' } ] }
        )
        allow(transport).to receive(:chat).and_return(tool_response)

        result = client.call(conversation)

        expect(result[:tool_calls]).to eq([ { id: "tc_1", name: "search", arguments: '{"q":"test"}' } ])
      end
    end

    context "with an OpenAI-compatible transport" do
      let(:transport) { instance_double(AgentHarness::OpenAICompatibleTransport) }
      let(:model) { "gpt-4o" }
      let(:client) { described_class.new(transport: transport, model: model, provider_type: :openai_compatible) }
      let(:conversation) do
        [
          { role: "system", content: "You are helpful." },
          { role: "user", content: "Find the issue" },
          {
            role: "assistant",
            content: "Let me search.",
            tool_calls: [ { id: "call_1", name: "search", arguments: { query: "issue" } } ]
          },
          { role: "tool", content: '{"results":[]}', tool_call_id: "call_1", tool_name: "search" },
          { role: "assistant", content: nil },
          { role: "user", content: "What did you find?" }
        ]
      end
      let(:expected_messages) do
        [
          { role: "system", content: "You are helpful." },
          { role: "user", content: "Find the issue" },
          {
            role: "assistant",
            content: "Let me search.",
            tool_calls: [
              {
                id: "call_1",
                type: "function",
                function: { name: "search", arguments: '{"query":"issue"}' }
              }
            ]
          },
          { role: "tool", content: '{"results":[]}', tool_call_id: "call_1" },
          { role: "user", content: "What did you find?" }
        ]
      end
      let(:expected_tools) do
        [
          {
            type: "function",
            function: {
              name: "search",
              description: "Search the project",
              parameters: tool_definitions.first[:inputSchema]
            }
          }
        ]
      end

      it "passes openai-formatted messages and tools to the transport" do
        allow(transport).to receive(:chat).and_return(response)

        client.call(conversation, tools: tool_definitions)

        expect(transport).to have_received(:chat) do |**kwargs|
          expect(kwargs[:messages]).to eq(expected_messages)
          expect(kwargs[:tools]).to eq(expected_tools)
          expect(kwargs[:model]).to eq(model)
          expect(kwargs[:stream]).to be(false)
        end
      end

      it "folds later system messages into the system prompt" do
        allow(transport).to receive(:chat).and_return(response)

        client.call([
          { role: "system", content: "You are helpful." },
          { role: "user", content: "Find the issue" },
          { role: "system", content: "## Added Project Context: Paid" },
          { role: "user", content: "What did you find?" }
        ])

        expect(transport).to have_received(:chat).with(
          hash_including(
            messages: [
              { role: "system", content: "You are helpful.\n\n## Added Project Context: Paid" },
              { role: "user", content: "Find the issue" },
              { role: "user", content: "What did you find?" }
            ]
          )
        )
      end

      it "returns nil tools when no definitions are provided" do
        allow(transport).to receive(:chat).and_return(response)

        client.call(conversation, tools: nil)

        expect(transport).to have_received(:chat).with(hash_including(tools: nil))
      end
    end
  end
end
