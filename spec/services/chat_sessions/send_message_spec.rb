# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::SendMessage do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:llm_response) do
    {
      content: "I can help with that.",
      tool_calls: [],
      tokens_input: 100,
      tokens_output: 50,
      model: "gpt-4o"
    }
  end
  let(:llm_client) { instance_double(Proc, call: llm_response) }
  let(:streaming_client) do
    Class.new do
      def call(_conversation, on_chunk: nil)
        on_chunk&.call("I can ")
        on_chunk&.call("help with that.")

        {
          content: "I can help with that.",
          tool_calls: [],
          tokens_input: 100,
          tokens_output: 50,
          model: "gpt-4o"
        }
      end
    end.new
  end
  let(:tool_definitions) do
    [
      {
        name: "search",
        description: "Search the project",
        inputSchema: { type: "object", properties: { query: { type: "string" } } }
      }
    ]
  end
  let(:expected_assistant_tool_call_entry) do
    {
      content: "Let me search for that.",
      tool_calls: [
        {
          id: "call_1",
          name: "search",
          arguments: { "query" => "test" }
        }
      ]
    }
  end

  describe ".call" do
    it "persists the user message" do
      expect {
        described_class.call(chat_session: chat_session, content: "Hello", llm_client: llm_client)
      }.to change { chat_session.messages.where(role: "user").count }.by(1)
    end

    it "persists the assistant response" do
      expect {
        described_class.call(chat_session: chat_session, content: "Hello", llm_client: llm_client)
      }.to change { chat_session.messages.where(role: "assistant").count }.by(1)
    end

    it "returns the assistant message" do
      result = described_class.call(chat_session: chat_session, content: "Hello", llm_client: llm_client)

      expect(result).to be_a(ChatMessage)
      expect(result.role).to eq("assistant")
      expect(result.content).to eq("I can help with that.")
    end

    it "persists token counts on the assistant message" do
      result = described_class.call(chat_session: chat_session, content: "Hello", llm_client: llm_client)

      expect(result.tokens_input).to eq(100)
      expect(result.tokens_output).to eq(50)
    end

    it "resets the idle timeout" do
      chat_session.update!(idle_timeout_at: 1.hour.ago)

      described_class.call(chat_session: chat_session, content: "Hello", llm_client: llm_client)
      chat_session.reload

      expect(chat_session.idle_timeout_at).to be_within(5.seconds).of(30.minutes.from_now)
    end

    it "raises when session is not active" do
      closed_session = create(:chat_session, :closed, account: account, created_by: user)

      expect {
        described_class.call(chat_session: closed_session, content: "Hello", llm_client: llm_client)
      }.to raise_error(ArgumentError, /active/)
    end

    it "raises when content is blank" do
      expect {
        described_class.call(chat_session: chat_session, content: "", llm_client: llm_client)
      }.to raise_error(ArgumentError, /blank/)
    end

    it "raises when content exceeds maximum length" do
      long_content = "x" * (described_class::MAX_CONTENT_LENGTH + 1)
      expect {
        described_class.call(chat_session: chat_session, content: long_content, llm_client: llm_client)
      }.to raise_error(ArgumentError, /maximum length/)
    end

    it "raises without llm_client when agent-harness is not integrated" do
      expect {
        described_class.call(chat_session: chat_session, content: "Hello")
      }.to raise_error(NotImplementedError, /agent-harness/)
    end

    it "creates a token usage record for the assistant response" do
      described_class.call(chat_session: chat_session, content: "Hello", llm_client: llm_client)

      usage = TokenUsage.last
      expect(usage.chat_session).to eq(chat_session)
      expect(usage.request_type).to eq("chat_message")
      expect(usage.input_tokens).to eq(100)
      expect(usage.output_tokens).to eq(50)
      expect(usage.llm_model).to eq("gpt-4o")
      expect(usage.cost_cents).to be >= 0
    end

    context "when session token limit is reached" do
      before do
        create(:tenant_setting, account: account,
          features: { "chat_settings" => { "chat_session_token_limit" => 100 } })
        create(:token_usage, :chat, chat_session: chat_session, input_tokens: 80, output_tokens: 30)
      end

      it "raises TokenLimitExceededError" do
        expect {
          described_class.call(chat_session: chat_session, content: "Hello", llm_client: llm_client)
        }.to raise_error(ChatSessions::TokenLimitExceededError, /token limit reached/)
      end

      it "does not persist the user message" do
        expect {
          described_class.call(chat_session: chat_session, content: "Hello", llm_client: llm_client)
        }.to raise_error(ChatSessions::TokenLimitExceededError)

        expect(chat_session.messages.where(role: "user", content: "Hello").count).to eq(0)
      end
    end

    context "when session token limit is increased after being reached" do
      before do
        tenant_setting = create(:tenant_setting, account: account,
          features: { "chat_settings" => { "chat_session_token_limit" => 100 } })
        create(:token_usage, :chat, chat_session: chat_session, input_tokens: 80, output_tokens: 30)

        # Increase the limit
        tenant_setting.update!(features: { "chat_settings" => { "chat_session_token_limit" => 500 } })
      end

      it "allows sending messages again" do
        result = described_class.call(chat_session: chat_session, content: "Hello", llm_client: llm_client)

        expect(result).to be_a(ChatMessage)
        expect(result.role).to eq("assistant")
      end
    end

    it "auto-generates a title from the first user message when untitled" do
      described_class.call(chat_session: chat_session, content: "How do I deploy to production?", llm_client: llm_client)
      chat_session.reload

      expect(chat_session.title).to eq("How do I deploy to production?")
    end

    it "does not overwrite an existing title" do
      chat_session.update!(title: "Existing title")

      described_class.call(chat_session: chat_session, content: "New message", llm_client: llm_client)
      chat_session.reload

      expect(chat_session.title).to eq("Existing title")
    end

    it "truncates long messages for the auto-generated title" do
      long_content = "x" * 200
      described_class.call(chat_session: chat_session, content: long_content, llm_client: llm_client)
      chat_session.reload

      expect(chat_session.title.length).to be <= 80
    end

    it "builds conversation from message history" do
      create(:chat_message, :system, chat_session: chat_session)
      create(:chat_message, chat_session: chat_session, content: "First question")
      create(:chat_message, :assistant, chat_session: chat_session)

      result = described_class.call(chat_session: chat_session, content: "Follow-up", llm_client: llm_client)

      expect(result).to be_persisted
      # 1 factory "First question" + 1 new "Follow-up" = 2 user messages
      expect(chat_session.messages.where(role: "user").count).to eq(2)
    end

    it "notifies persisted messages in creation order" do
      persisted_messages = []

      described_class.call(
        chat_session: chat_session,
        content: "Hello",
        llm_client: llm_client,
        stream_message_id: "stream-123",
        on_message_persisted: ->(message, stream_message_id: nil) {
          persisted_messages << [ message.role, message.content, stream_message_id ]
        }
      )

      expect(persisted_messages).to eq([
        [ "user", "Hello", nil ],
        [ "assistant", "I can help with that.", "stream-123" ]
      ])
    end

    it "passes streamed chunks through when the llm client supports chunk callbacks" do
      chunks = []

      described_class.call(
        chat_session: chat_session,
        content: "Hello",
        llm_client: streaming_client,
        on_chunk: ->(chunk) { chunks << chunk }
      )

      expect(chunks).to eq([ "I can ", "help with that." ])
    end

    it "replays response content when the llm client does not support chunk callbacks" do
      chunks = []

      described_class.call(
        chat_session: chat_session,
        content: "Hello",
        llm_client: llm_client,
        on_chunk: ->(chunk) { chunks << chunk }
      )

      expect(chunks.join).to eq("I can help with that.")
      expect(chunks.length).to be > 1
    end

    it "passes tool definitions when the llm client supports tools" do
      tool_aware_client = Class.new do
        attr_reader :seen_tools

        def initialize(response)
          @response = response
        end

        def call(_conversation, tools: nil)
          @seen_tools = tools
          @response
        end
      end.new(llm_response)
      allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user).and_return(tool_definitions)

      described_class.call(chat_session: chat_session, content: "Hello", llm_client: tool_aware_client)

      expect(tool_aware_client.seen_tools).to eq(tool_definitions)
    end

    it "falls back when the llm client does not support tools" do
      expect {
        described_class.call(chat_session: chat_session, content: "Hello", llm_client: llm_client)
      }.not_to raise_error
    end

    context "with tool calls in response" do
      let(:tool_llm_client) { build_stateful_llm_client(successful_tool_llm_responses) }

      before do
        allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user).and_return(tool_definitions)
        allow(Tools::Registry).to receive(:dispatch).and_return(successful_tool_dispatch_result)
      end

      it "persists assistant, tool call, tool result, and final assistant messages in order" do
        described_class.call(
          chat_session: chat_session, content: "Search for test", llm_client: tool_llm_client
        )

        expect(chat_session.messages.order(:created_at).pluck(:role, :content)).to eq([
          [ "user", "Search for test" ],
          [ "assistant", "Let me search for that." ],
          [ "assistant", nil ],
          [ "tool", successful_tool_dispatch_result.to_json ],
          [ "assistant", "I found the matching results." ]
        ])
      end

      it "dispatches tools with parsed arguments, the session, and the session user" do
        expect_dispatch_with_parsed_arguments
      end

      it "creates a single aggregate token usage row for the full turn" do
        assistant_message = nil

        expect {
          assistant_message = described_class.call(
            chat_session: chat_session, content: "Search for test", llm_client: tool_llm_client
          )
        }.to change(TokenUsage, :count).by(1)

        usage = TokenUsage.last

        expect(usage.chat_session).to eq(chat_session)
        expect(usage.request_type).to eq("chat_message")
        expect(usage.input_tokens).to eq(125)
        expect(usage.output_tokens).to eq(65)
        expect(assistant_message.tokens_input).to eq(125)
        expect(assistant_message.tokens_output).to eq(65)
      end

      it "notifies tool messages so live threads can render them" do
        roles = []

        described_class.call(
          chat_session: chat_session,
          content: "Search for test",
          llm_client: tool_llm_client,
          on_message_persisted: ->(message, **) { roles << message.role }
        )

        expect(roles).to eq(%w[user assistant assistant tool assistant])
      end

      it "replays persisted tool results in follow-up turns" do
        described_class.call(
          chat_session: chat_session, content: "Search for test", llm_client: tool_llm_client
        )

        follow_up_client = instance_double(Proc)
        allow(follow_up_client).to receive(:call) do |conversation|
          expect_follow_up_tool_round_trip(conversation)
          llm_response
        end

        described_class.call(chat_session: chat_session, content: "What happened?", llm_client: follow_up_client)

        expect(follow_up_client).to have_received(:call)
      end
    end

    context "when tool dispatch fails" do
      let(:tool_llm_client) do
        build_stateful_llm_client([
          tool_response(content: "Let me search for that.", tokens_input: 30, tokens_output: 10),
          final_response(content: "The tool failed, but I recovered.", tokens_input: 20, tokens_output: 8)
        ])
      end

      it "captures the structured tool error and continues the loop" do
        allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user).and_return(tool_definitions)
        allow(Tools::Registry).to receive(:dispatch).and_raise(StandardError, "boom")
        allow(Rails.logger).to receive(:error)

        result = described_class.call(
          chat_session: chat_session, content: "Search for test", llm_client: tool_llm_client
        )

        tool_result_message = chat_session.messages.find_by!(role: "tool")

        expect(result.content).to eq("The tool failed, but I recovered.")
        expect(tool_result_message.tool_result).to eq(
          {
            "status" => "error",
            "error" => "internal_error",
            "message" => "boom"
          }
        )
        expect(Rails.logger).to have_received(:error).with(
          hash_including(message: "chat_tool_dispatch.failed", chat_session_id: chat_session.id, tool_name: "search")
        )
      end
    end

    context "when the model keeps requesting tools" do
      let(:tool_loop_response) do
        {
          content: nil,
          tool_calls: [
            { id: "call_1", name: "search", arguments: { "query" => "test" } }
          ],
          tokens_input: 10,
          tokens_output: 5,
          model: "gpt-4o"
        }
      end
      let(:tool_llm_client) do
        build_stateful_llm_client(Array.new(ChatSessions::AgentLoop::MAX_TOOL_ITERATIONS, tool_loop_response))
      end

      it "caps the loop and persists a final user-visible note" do
        allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user).and_return(tool_definitions)
        allow(Tools::Registry).to receive(:dispatch).and_return({ "status" => "ok" })

        result = described_class.call(
          chat_session: chat_session, content: "Keep going", llm_client: tool_llm_client
        )

        expect(tool_llm_client.seen_conversations.length).to eq(ChatSessions::AgentLoop::MAX_TOOL_ITERATIONS)
        expect(result.content).to include("maximum number of tool iterations")
        expect(chat_session.messages.where(role: "tool").count).to eq(ChatSessions::AgentLoop::MAX_TOOL_ITERATIONS)
      end
    end
  end

  def expect_follow_up_tool_round_trip(conversation)
    assistant_tool_call_entry = conversation.find do |message|
      message[:role] == "assistant" && message[:tool_calls].present?
    end
    tool_entry = conversation.find { |message| message[:role] == "tool" }

    expect(assistant_tool_call_entry).to include(expected_assistant_tool_call_entry)
    expect(tool_entry).to include(
      content: successful_tool_dispatch_result,
      tool_call_id: "call_1",
      tool_name: "search"
    )
  end

  def build_stateful_llm_client(responses)
    Class.new do
      attr_reader :responses, :seen_conversations, :seen_tools

      def initialize(responses)
        @responses = responses
        @seen_conversations = []
      end

      def call(conversation, tools: nil)
        @seen_conversations << conversation.deep_dup
        @seen_tools = tools
        responses.fetch(seen_conversations.length - 1)
      end
    end.new(responses)
  end

  def successful_tool_llm_responses
    [
      tool_response(content: "Let me search for that.", tokens_input: 100, tokens_output: 50),
      final_response(content: "I found the matching results.", tokens_input: 25, tokens_output: 15)
    ]
  end

  def successful_tool_dispatch_result
    { "status" => "ok", "results" => [ "match" ] }
  end

  def tool_response(content:, tokens_input:, tokens_output:, arguments: { "query" => "test" })
    {
      content: content,
      tool_calls: [
        { id: "call_1", name: "search", arguments: arguments }
      ],
      tokens_input: tokens_input,
      tokens_output: tokens_output,
      model: "gpt-4o"
    }
  end

  def final_response(content:, tokens_input:, tokens_output:)
    {
      content: content,
      tool_calls: [],
      tokens_input: tokens_input,
      tokens_output: tokens_output,
      model: "gpt-4o"
    }
  end

  def expect_dispatch_with_parsed_arguments
    described_class.call(
      chat_session: chat_session,
      content: "Search for test",
      llm_client: build_stateful_llm_client([
        tool_response(content: "Let me search for that.", tokens_input: 100, tokens_output: 50, arguments: "{\"query\":\"test\"}"),
        final_response(content: "Done.", tokens_input: 10, tokens_output: 5)
      ])
    )

    expect(Tools::Registry).to have_received(:dispatch).with(
      name: "search",
      arguments: { "query" => "test" },
      user: user,
      session: chat_session
    )
  end
end
