# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::AgentLoop do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:tool_definitions) { [ { name: "anything", description: "x", inputSchema: { type: "object" } } ] }
  let(:mixed_tool_client) do
    Class.new do
      def call(_conversation, tools: nil)
        {
          content: "Looking, then acting.",
          tool_calls: [
            { id: "read", name: "search", arguments: { "q" => "x" } },
            { id: "write", name: "trigger_agent_run", arguments: {} }
          ],
          tokens_input: 5, tokens_output: 5, model: "gpt-4o"
        }
      end
    end.new
  end

  describe "#run" do
    context "when the model requests a write tool" do
      let(:llm_client) do
        Class.new do
          def initialize(responses)
            @responses = responses
            @index = 0
          end

          def call(_conversation, tools: nil)
            @index += 1
            @responses.fetch(@index - 1)
          end
        end.new([
          {
            content: "I'll kick off an agent run.",
            tool_calls: [
              { id: "call_1", name: "trigger_agent_run", arguments: { "project_id" => 1, "issue_id" => 2 } }
            ],
            tokens_input: 50,
            tokens_output: 20,
            model: "gpt-4o"
          }
        ])
      end

      before do
        allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user, session: anything).and_return(tool_definitions)
        allow(Tools::Registry).to receive(:dispatch)
      end

      it "pauses the loop and returns nil instead of dispatching" do
        result = described_class.new(chat_session: chat_session, llm_client: llm_client).run

        expect(result).to be_nil
        expect(Tools::Registry).not_to have_received(:dispatch)
      end

      it "persists the assistant content and a pending tool-call message" do
        described_class.new(chat_session: chat_session, llm_client: llm_client).run

        expect(chat_session.messages.chronological.pluck(:role, :content, :tool_status)).to eq([
          [ "assistant", "I'll kick off an agent run.", nil ],
          [ "assistant", nil, "pending" ]
        ])
      end

      it "persists the requested tool name and arguments on the pending message" do
        described_class.new(chat_session: chat_session, llm_client: llm_client).run

        pending_message = chat_session.messages.find_by(tool_status: "pending")
        expect(pending_message.tool_name).to eq("trigger_agent_run")
        expect(pending_message.tool_call_id).to eq("call_1")
        expect(pending_message.tool_arguments).to eq("project_id" => 1, "issue_id" => 2)
      end

      it "notifies the pending tool call so the UI can render a confirmation" do
        notified = []

        described_class.new(
          chat_session: chat_session,
          llm_client: llm_client,
          on_message_persisted: ->(message, **) { notified << [ message.role, message.tool_status ] }
        ).run

        expect(notified).to include([ "assistant", "pending" ])
      end

      it "persists token usage for the paused turn so the cost is not lost" do
        expect {
          described_class.new(chat_session: chat_session, llm_client: llm_client).run
        }.to change { chat_session.token_usages.for_chat.count }.by(1)

        expect(chat_session.token_usages.for_chat.last).to have_attributes(
          input_tokens: 50,
          output_tokens: 20,
          llm_model: "gpt-4o",
          request_type: "chat_message"
        )
      end

      it "surfaces every write tool in the batch as its own pending confirmation" do
        multi_client = Class.new do
          def call(_conversation, tools: nil)
            {
              content: "Doing several things.",
              tool_calls: [
                { id: "a", name: "trigger_agent_run", arguments: {} },
                { id: "b", name: "cancel_agent_run", arguments: {} }
              ],
              tokens_input: 5, tokens_output: 5, model: "gpt-4o"
            }
          end
        end.new

        described_class.new(chat_session: chat_session, llm_client: multi_client).run

        pending = chat_session.messages.where(tool_status: "pending")
        expect(pending.count).to eq(2)
        expect(pending.pluck(:tool_call_id)).to contain_exactly("a", "b")
      end

      it "creates a draft CIR before showing the pending confirmation for post-dispatch tools" do
        allow(Tools::Registry).to receive(:post_dispatch_confirmation?).with("record_change_intent").and_return(true)
        allow(Tools::Registry).to receive(:post_dispatch_confirmation?).with("trigger_agent_run").and_return(false)
        allow(Tools::Registry).to receive(:dispatch).and_return({ "id" => 44, "status" => "draft" })

        cir_client = Class.new do
          def call(_conversation, tools: nil)
            {
              content: "I drafted a CIR.",
              tool_calls: [
                { id: "cir", name: "record_change_intent", arguments: { "title" => "Use Redis", "intent" => "Share state" } }
              ],
              tokens_input: 7, tokens_output: 5, model: "gpt-4o"
            }
          end
        end.new

        described_class.new(chat_session: chat_session, llm_client: cir_client).run

        pending = chat_session.messages.find_by(tool_status: "pending")
        expect(pending.tool_name).to eq("record_change_intent")
        expect(pending.tool_result).to eq({ "id" => 44, "status" => "draft" })
      end

      it "runs read-only tools immediately when mixed with a write tool in one batch" do
        allow(Tools::Registry).to receive_messages(
          dispatch: { "status" => "ok" },
          post_dispatch_confirmation?: false
        )

        described_class.new(chat_session: chat_session, llm_client: mixed_tool_client).run

        expect(Tools::Registry).to have_received(:dispatch).once

        read_result = chat_session.messages.find_by(role: "tool", tool_call_id: "read")
        expect(read_result).to be_present
        expect(read_result.tool_result).to eq({ "status" => "ok" })

        expect(chat_session.messages.find_by(tool_call_id: "write", tool_status: "pending")).to be_present
      end
    end

    context "when the model requests only read-only tools" do
      let(:llm_client) do
        Class.new do
          def initialize
            @called = false
          end

          def call(_conversation, tools: nil)
            @called = !@called
            if @called
              {
                content: "Searching.",
                tool_calls: [ { id: "call_1", name: "search", arguments: { "q" => "x" } } ],
                tokens_input: 10, tokens_output: 5, model: "gpt-4o"
              }
            else
              { content: "Done.", tool_calls: [], tokens_input: 8, tokens_output: 4, model: "gpt-4o" }
            end
          end
        end.new
      end

      it "dispatches the tool immediately and never pauses" do
        allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user, session: anything).and_return(tool_definitions)
        allow(Tools::Registry).to receive_messages(
          dispatch: { "status" => "ok" },
          post_dispatch_confirmation?: false
        )

        result = described_class.new(chat_session: chat_session, llm_client: llm_client).run

        expect(result).not_to be_nil
        expect(Tools::Registry).to have_received(:dispatch).once
        expect(chat_session.messages.where.not(tool_status: nil).count).to eq(0)
      end
    end

    context "when the model returns no content or tool calls" do
      let(:llm_client) do
        Class.new do
          def call(_conversation, tools: nil)
            { content: nil, tool_calls: [], tokens_input: 12, tokens_output: 0, model: "glm-5.1" }
          end
        end.new
      end

      it "persists a visible assistant message instead of silently completing" do
        allow(Rails.logger).to receive(:warn)

        result = described_class.new(chat_session: chat_session, llm_client: llm_client).run

        expect(result).to be_a(ChatMessage)
        expect(result.content).to eq(described_class::EMPTY_RESPONSE_MESSAGE)
        expect(result).to have_attributes(tokens_input: 12, tokens_output: 0, model: "glm-5.1")
        expect(chat_session.messages.where(role: "assistant").last).to eq(result)
        expect(Rails.logger).to have_received(:warn).with(hash_including(
          message: "chat_agent_loop.empty_response",
          chat_session_id: chat_session.id,
          runner_id: chat_session.runner_id,
          model: "glm-5.1",
          tokens_input: 12,
          tokens_output: 0
        ))
      end
    end
  end

  describe "#build_conversation" do
    let(:service) { described_class.new(chat_session: chat_session, llm_client: instance_double(Proc)) }

    it "regroups persisted assistant tool-call rows onto the preceding assistant message" do
      create(:chat_message, :system, chat_session: chat_session)
      create(:chat_message, chat_session: chat_session, role: "user", content: "Search for test")
      create(:chat_message, :assistant, chat_session: chat_session, content: "Let me search for that.")
      create_tool_roundtrip_rows(result: { "status" => "ok", "results" => [ "match" ] })

      expect(service.send(:build_conversation)).to include(
        {
          role: "assistant",
          content: "Let me search for that.",
          tool_calls: [ { id: "call_1", name: "search", arguments: { "query" => "test" } } ]
        },
        { role: "tool", content: { "status" => "ok", "results" => [ "match" ] }, tool_call_id: "call_1", tool_name: "search" }
      )
    end

    it "recreates assistant tool-call entries even when the original response had no assistant text" do
      create(:chat_message, chat_session: chat_session, role: "user", content: "Search for test")
      create_tool_roundtrip_rows(result: { "status" => "ok" })

      expect(service.send(:build_conversation)).to include(
        role: "assistant",
        content: nil,
        tool_calls: [ { id: "call_1", name: "search", arguments: { "query" => "test" } } ]
      )
    end

    def create_tool_roundtrip_rows(result:)
      create(:chat_message, :tool_call, chat_session: chat_session,
        tool_call_id: "call_1", tool_name: "search", tool_arguments: { "query" => "test" })
      create(:chat_message, :tool, chat_session: chat_session,
        tool_call_id: "call_1", tool_name: "search", content: result.to_json, tool_result: result)
    end
  end
end
