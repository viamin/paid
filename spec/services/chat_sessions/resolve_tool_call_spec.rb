# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ResolveToolCall do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:tool_definitions) { [ { name: "trigger_agent_run", description: "x", inputSchema: { type: "object" } } ] }
  let(:dispatch_result) { { "id" => 99, "status" => "queued" } }
  let(:final_response) do
    { content: "Done.", tool_calls: [], tokens_input: 12, tokens_output: 6, model: "gpt-4o" }
  end
  let(:llm_client) do
    Class.new do
      attr_reader :seen_conversations

      def initialize(response)
        @response = response
        @seen_conversations = []
      end

      def call(conversation, tools: nil)
        @seen_conversations << conversation
        @response
      end
    end.new(final_response)
  end

  let(:tool_call_message) do
    create(:chat_message,
      chat_session: chat_session,
      role: "assistant",
      content: nil,
      tool_name: "trigger_agent_run",
      tool_call_id: "call_1",
      tool_arguments: { "project_id" => 1, "issue_id" => 2 },
      tool_status: "pending")
  end

  before do
    allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user, session: anything).and_return(tool_definitions)
  end

  describe ".call approve" do
    before { allow(Tools::Registry).to receive(:dispatch).and_return(dispatch_result) }

    it "dispatches the tool with confirmed injected as true" do
      described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: "approve", llm_client: llm_client
      )

      expect(Tools::Registry).to have_received(:dispatch).with(
        hash_including(
          name: "trigger_agent_run",
          arguments: hash_including("confirmed" => true, "project_id" => 1, "issue_id" => 2),
          user: user,
          session: chat_session
        )
      )
    end

    it "persists the dispatch result and marks the tool call approved" do
      result = described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :approve, llm_client: llm_client
      )

      expect(tool_call_message.reload.tool_status).to eq("approved")

      tool_result = chat_session.messages.find_by(role: "tool")
      expect(tool_result.tool_result).to eq(dispatch_result)
      expect(tool_result.tool_call_id).to eq("call_1")
      expect(result.role).to eq("assistant")
      expect(result.content).to eq("Done.")
    end

    it "resumes the loop with the completed tool round-trip in context" do
      described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :approve, llm_client: llm_client
      )

      conversation = llm_client.seen_conversations.last
      tool_entry = conversation.find { |message| message[:role] == "tool" }
      expect(tool_entry).to include(content: dispatch_result, tool_call_id: "call_1")
    end

    it "uses post-dispatch confirmation resolution for draft CIRs" do
      tool_call_message.update!(tool_name: "record_change_intent", tool_result: { "id" => 123, "status" => "draft" })
      allow(Tools::Registry).to receive(:post_dispatch_confirmation?).with("record_change_intent").and_return(true)
      allow(Tools::Registry).to receive(:resolve_confirmation).and_return({ "id" => 123, "status" => "active" })

      described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :approve, llm_client: llm_client
      )

      expect(Tools::Registry).not_to have_received(:dispatch)
      expect(Tools::Registry).to have_received(:resolve_confirmation).with(
        name: "record_change_intent",
        decision: :approve,
        pending_result: { "id" => 123, "status" => "draft" },
        user: user,
        session: chat_session
      )
    end

    it "rolls back to pending when post-dispatch approval resolution fails" do
      tool_call_message.update!(tool_name: "record_change_intent", tool_result: { "id" => 123, "status" => "draft" })
      allow(Tools::Registry).to receive(:post_dispatch_confirmation?).with("record_change_intent").and_return(true)
      allow(Tools::Registry).to receive(:resolve_confirmation).and_raise(Pundit::NotAuthorizedError, "not allowed")

      described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :approve, llm_client: llm_client
      )

      expect(tool_call_message.reload.tool_status).to eq("pending")
      expect(chat_session.messages.where(role: "tool")).to be_empty
      expect(llm_client.seen_conversations).to be_empty
    end

    it "leaves the confirmation retriable after a failed post-dispatch resolution" do
      tool_call_message.update!(tool_name: "record_change_intent", tool_result: { "id" => 123, "status" => "draft" })
      allow(Tools::Registry).to receive(:post_dispatch_confirmation?).with("record_change_intent").and_return(true)
      attempts = 0
      allow(Tools::Registry).to receive(:resolve_confirmation) do
        attempts += 1
        raise Pundit::NotAuthorizedError, "transient" if attempts == 1

        { "id" => 123, "status" => "active" }
      end

      described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :approve, llm_client: llm_client
      )
      expect(tool_call_message.reload.tool_status).to eq("pending")

      described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :approve, llm_client: llm_client
      )

      expect(tool_call_message.reload.tool_status).to eq("approved")
      expect(chat_session.messages.find_by(role: "tool").tool_result).to eq({ "id" => 123, "status" => "active" })
    end
  end

  describe ".call deny" do
    before { allow(Tools::Registry).to receive(:dispatch) }

    it "does not dispatch the tool and feeds a denied result" do
      result = described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :deny, llm_client: llm_client
      )

      expect(Tools::Registry).not_to have_received(:dispatch)
      expect(tool_call_message.reload.tool_status).to eq("denied")

      tool_result = chat_session.messages.find_by(role: "tool")
      expect(tool_result.tool_result).to include("status" => "denied")
      expect(result.content).to eq("Done.")
    end

    it "routes post-dispatch denials through the tool resolver" do
      tool_call_message.update!(tool_name: "record_change_intent", tool_result: { "id" => 22, "status" => "draft" })
      allow(Tools::Registry).to receive(:post_dispatch_confirmation?).with("record_change_intent").and_return(true)
      allow(Tools::Registry).to receive(:resolve_confirmation).and_return({ "id" => 22, "status" => "denied" })

      described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :deny, llm_client: llm_client
      )

      expect(Tools::Registry).not_to have_received(:dispatch)
      expect(chat_session.messages.find_by(role: "tool").tool_result).to eq({ "id" => 22, "status" => "denied" })
    end

    it "rolls back to pending when post-dispatch denial resolution fails" do
      tool_call_message.update!(tool_name: "record_change_intent", tool_result: { "id" => 22, "status" => "draft" })
      allow(Tools::Registry).to receive(:post_dispatch_confirmation?).with("record_change_intent").and_return(true)
      allow(Tools::Registry).to receive(:resolve_confirmation).and_raise(ArgumentError, "missing draft id")

      described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :deny, llm_client: llm_client
      )

      expect(tool_call_message.reload.tool_status).to eq("pending")
      expect(chat_session.messages.where(role: "tool")).to be_empty
      expect(llm_client.seen_conversations).to be_empty
    end
  end

  describe "Pundit re-check at execution" do
    it "captures an authorization failure as a structured tool result without crashing" do
      allow(Tools::Registry).to receive(:dispatch).and_raise(Pundit::NotAuthorizedError, "not allowed")

      described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :approve, llm_client: llm_client
      )

      tool_result = chat_session.messages.find_by(role: "tool")
      expect(tool_result.tool_result).to eq(
        "status" => "error",
        "error" => "unauthorized",
        "message" => "not allowed"
      )
    end
  end

  describe "validation" do
    it "rejects a tool call that is not pending" do
      tool_call_message.update!(tool_status: "approved")

      expect {
        described_class.call(
          chat_session: chat_session, tool_call_message: tool_call_message,
          decision: :approve, llm_client: llm_client
        )
      }.to raise_error(ArgumentError, /not awaiting confirmation/)
    end

    it "rejects an unknown decision" do
      expect {
        described_class.call(
          chat_session: chat_session, tool_call_message: tool_call_message,
          decision: :maybe, llm_client: llm_client
        )
      }.to raise_error(ArgumentError, /approve or deny/)
    end
  end

  describe "concurrent resolution safety" do
    before { allow(Tools::Registry).to receive(:dispatch).and_return(dispatch_result) }

    it "rejects a second resolution of the same tool call so the tool cannot run twice" do
      described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :approve, llm_client: llm_client
      )

      expect {
        described_class.call(
          chat_session: chat_session, tool_call_message: tool_call_message,
          decision: :approve, llm_client: llm_client
        )
      }.to raise_error(ArgumentError, /not awaiting confirmation/)

      expect(Tools::Registry).to have_received(:dispatch).once
    end
  end

  describe "runner fallback when resuming the loop" do
    before { allow(Tools::Registry).to receive(:dispatch).and_return(dispatch_result) }

    it "switches to a configured fallback runner and retries when the resumed loop hits a provider error" do
      fallback_runner = configure_chat_fallback
      fallback_client = inspecting_llm_client(final_response)
      allow(ChatSessions::BuildLlmClient).to receive(:call)
        .with(chat_session: chat_session).and_return(fallback_client)

      result = described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :approve, llm_client: rate_limited_llm_client
      )

      expect(result.content).to eq("Done.")
      expect(chat_session.reload.runner).to eq(fallback_runner)

      notice = chat_session.messages.detect(&:fallback_notice?)
      expect(notice).to be_present
      expect(notice.content).to include("Switching to #{fallback_runner.display_name} and continuing.")
      expect(notice.metadata).to include("fallback_notice" => true)

      # the synthetic notice is never replayed back to the fallback model
      expect(fallback_client.seen_conversations.last).not_to include(
        hash_including(content: notice.content)
      )
    end

    it "re-raises the provider error when no fallback runner is configured" do
      expect {
        described_class.call(
          chat_session: chat_session, tool_call_message: tool_call_message,
          decision: :approve, llm_client: rate_limited_llm_client
        )
      }.to raise_error(AgentHarness::RateLimitError)
    end
  end

  describe "several pending tool calls" do
    let(:second_tool_call_message) do
      create(:chat_message,
        chat_session: chat_session,
        role: "assistant",
        content: nil,
        tool_name: "cancel_agent_run",
        tool_call_id: "call_2",
        tool_arguments: { "agent_run_id" => 5 },
        tool_status: "pending")
    end

    before do
      second_tool_call_message
      allow(Tools::Registry).to receive(:dispatch).and_return(dispatch_result)
    end

    it "does not resume the loop until the last pending tool call is resolved" do
      result = described_class.call(
        chat_session: chat_session, tool_call_message: tool_call_message,
        decision: :approve, llm_client: llm_client
      )

      expect(result).to be_nil
      expect(llm_client.seen_conversations).to be_empty

      result = described_class.call(
        chat_session: chat_session, tool_call_message: second_tool_call_message,
        decision: :deny, llm_client: llm_client
      )

      expect(result).to be_present
      expect(llm_client.seen_conversations).to be_one
      expect(tool_call_message.reload.tool_status).to eq("approved")
      expect(second_tool_call_message.reload.tool_status).to eq("denied")
    end
  end

  def rate_limited_llm_client
    Class.new do
      def call(*)
        raise AgentHarness::RateLimitError, "API rate limit exceeded"
      end
    end.new
  end

  def inspecting_llm_client(response)
    Class.new do
      attr_reader :seen_conversations

      def initialize(response)
        @response = response
        @seen_conversations = []
      end

      def call(conversation, **)
        @seen_conversations << conversation.deep_dup
        @response
      end
    end.new(response)
  end

  def configure_chat_fallback
    primary_runner = create(:runner, :api_key, user: user, runner_key: "opencode",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })
    fallback_runner = create(:runner, :api_key, user: user, runner_key: "claude",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "anthropic"))

    user.settings.update!(kb_chat_fallback_runners: [ "claude" ])
    chat_session.update!(runner: primary_runner)
    fallback_runner
  end
end
