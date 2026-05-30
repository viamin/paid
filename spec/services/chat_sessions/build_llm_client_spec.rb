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

    context "with a subscription runner (no API key)" do
      it "raises a setup error" do
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

    context "without a runner" do
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
    let(:transport) { instance_double(AgentHarness::TextTransport) }
    let(:model) { "claude-sonnet-4-20250514" }
    let(:client) { described_class.new(transport: transport, model: model, provider_type: :anthropic) }

    let(:conversation) do
      [
        { role: "system", content: "You are helpful." },
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi there!" },
        { role: "user", content: "How are you?" }
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

    it "calls transport.chat with formatted messages" do
      allow(transport).to receive(:chat).and_return(response)

      result = client.call(conversation)

      expect(transport).to have_received(:chat) do |**kwargs|
        messages = kwargs[:messages]
        expect(messages).to include({ role: "system", content: "You are helpful." })
        expect(messages).to include({ role: "user", content: "How are you?" })
        expect(kwargs[:model]).to eq(model)
        expect(kwargs[:stream]).to be(false)
      end
      expect(result[:content]).to eq("I'm doing well!")
      expect(result[:model]).to eq("claude-sonnet-4-20250514")
      expect(result[:tokens_input]).to eq(20)
      expect(result[:tokens_output]).to eq(10)
    end

    it "streams text chunks through on_chunk callback" do
      chunks_received = []

      allow(transport).to receive(:chat) do |**opts, &block|
        block.call({ type: :text, content: "Hello" })
        block.call({ type: :text, content: " world" })
        block.call({ type: :usage, input_tokens: 10, output_tokens: 5 })
        block.call({ type: :done })
        response
      end

      client.call(conversation, on_chunk: ->(chunk) { chunks_received << chunk })

      expect(chunks_received).to eq([ "Hello", " world" ])
    end

    it "filters out nil-content messages" do
      conversation_with_nil = conversation + [ { role: "tool", content: nil } ]

      allow(transport).to receive(:chat).and_return(response)

      client.call(conversation_with_nil)

      expect(transport).to have_received(:chat) do |**kwargs|
        expect(kwargs[:messages].size).to eq(4)
        expect(kwargs[:messages].map { |m| m[:content] }).to all(be_present)
      end
    end

    it "preserves tool_call_id and tool_name metadata in formatted messages" do
      conversation_with_tools = conversation + [
        { role: "assistant", content: "Let me search.", tool_call_id: "tc_1", tool_name: "search" },
        { role: "tool", content: '{"results":[]}', tool_call_id: "tc_1", tool_name: "search" }
      ]

      allow(transport).to receive(:chat).and_return(response)

      client.call(conversation_with_tools)

      expect(transport).to have_received(:chat) do |**kwargs|
        tool_msg = kwargs[:messages].find { |m| m[:tool_call_id] == "tc_1" && m[:role] == "assistant" }
        expect(tool_msg).to include(tool_call_id: "tc_1", tool_name: "search", content: "Let me search.")

        result_msg = kwargs[:messages].find { |m| m[:role] == "tool" }
        expect(result_msg).to include(tool_call_id: "tc_1", tool_name: "search", content: '{"results":[]}')
      end
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
end
