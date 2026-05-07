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

    context "with tool calls in response" do
      let(:tool_llm_response) do
        {
          content: "Let me search for that.",
          tool_calls: [
            { id: "call_1", name: "search", arguments: { query: "test" } }
          ],
          tokens_input: 100,
          tokens_output: 50,
          model: "gpt-4o"
        }
      end
      let(:tool_llm_client) { instance_double(Proc, call: tool_llm_response) }

      it "persists tool call and result messages" do
        described_class.call(
          chat_session: chat_session, content: "Search for test", llm_client: tool_llm_client
        )

        tool_call_msg = chat_session.messages.find_by(tool_name: "search", role: "assistant")
        expect(tool_call_msg).to be_present
        expect(tool_call_msg.tool_call_id).to eq("call_1")
        expect(tool_call_msg.tool_arguments).to eq({ "query" => "test" })

        tool_result_msg = chat_session.messages.find_by(role: "tool")
        expect(tool_result_msg).to be_present
        expect(tool_result_msg.tool_call_id).to eq("call_1")
        expect(JSON.parse(tool_result_msg.content)).to eq({ "status" => "not_implemented" })
        expect(tool_result_msg.tool_result).to eq({ "status" => "not_implemented" })
      end

      it "notifies tool messages so live threads can render them" do
        roles = []

        described_class.call(
          chat_session: chat_session,
          content: "Search for test",
          llm_client: tool_llm_client,
          on_message_persisted: ->(message, **) { roles << message.role }
        )

        expect(roles).to eq(%w[user assistant assistant tool])
      end

      it "replays persisted tool results in follow-up turns" do
        described_class.call(
          chat_session: chat_session, content: "Search for test", llm_client: tool_llm_client
        )

        follow_up_client = instance_double(Proc)
        allow(follow_up_client).to receive(:call) do |conversation|
          tool_entry = conversation.find { |message| message[:role] == "tool" }

          expect(tool_entry).to include(
            content: { "status" => "not_implemented" },
            tool_call_id: "call_1",
            tool_name: "search"
          )

          llm_response
        end

        described_class.call(chat_session: chat_session, content: "What happened?", llm_client: follow_up_client)

        expect(follow_up_client).to have_received(:call)
      end
    end
  end
end
