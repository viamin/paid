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
    allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user).and_return(tool_definitions)
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
end
