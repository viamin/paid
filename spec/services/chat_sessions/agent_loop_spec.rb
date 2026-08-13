# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::AgentLoop do
  # @spec CHAT-API-003
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

    context "when auto-approve is enabled for the session" do
      let(:chat_session) { create(:chat_session, account: account, created_by: user, auto_approve: true) }
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
            tokens_input: 50, tokens_output: 20, model: "gpt-4o"
          },
          { content: "Done.", tool_calls: [], tokens_input: 5, tokens_output: 2, model: "gpt-4o" }
        ])
      end

      let(:cir_client) do
        Class.new do
          def initialize
            @called = false
          end

          def call(_conversation, tools: nil)
            @called = !@called
            if @called
              {
                content: "I drafted a CIR.",
                tool_calls: [
                  { id: "cir", name: "record_change_intent", arguments: { "title" => "Use Redis", "intent" => "Share state" } }
                ],
                tokens_input: 7, tokens_output: 5, model: "gpt-4o"
              }
            else
              { content: "Done.", tool_calls: [], tokens_input: 3, tokens_output: 2, model: "gpt-4o" }
            end
          end
        end.new
      end

      let(:issue_client) do
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
            content: "I'll file a new issue.",
            tool_calls: [ { id: "issue_call", name: "create_issue", arguments: { "project_id" => 1, "title" => "Bug" } } ],
            tokens_input: 40, tokens_output: 15, model: "gpt-4o"
          },
          { content: "Filed.", tool_calls: [], tokens_input: 4, tokens_output: 2, model: "gpt-4o" }
        ])
      end

      let(:malformed_auto_approve_client) do
        Class.new do
          def initialize
            @called = false
          end

          def call(_conversation, tools: nil)
            @called = !@called
            return { content: "I need the project id before I can start that run.", tool_calls: [], tokens_input: 5, tokens_output: 2, model: "gpt-4o" } unless @called

            {
              content: "I'll kick off an agent run.",
              tool_calls: [ { id: "call_1", name: "trigger_agent_run", arguments: {} } ],
              tokens_input: 50, tokens_output: 20, model: "gpt-4o"
            }
          end
        end.new
      end

      before do
        allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user, session: anything).and_return(tool_definitions)
        allow(Tools::Registry).to receive(:dispatch).and_return({ "id" => 99, "status" => "queued" })
      end

      it "dispatches the write tool with confirmed injected and never pauses" do
        result = described_class.new(chat_session: chat_session, llm_client: llm_client).run

        expect(result).to be_present
        expect(Tools::Registry).to have_received(:dispatch).with(
          hash_including(
            name: "trigger_agent_run",
            arguments: hash_including("confirmed" => true, "project_id" => 1, "issue_id" => 2),
            user: user,
            session: chat_session
          )
        )
      end

      it "marks the tool call approved and persists the result instead of a pending confirmation" do
        described_class.new(chat_session: chat_session, llm_client: llm_client).run

        expect(chat_session.messages.where(tool_status: "pending")).not_to exist
        approved = chat_session.messages.find_by(tool_status: "approved")
        expect(approved.tool_name).to eq("trigger_agent_run")
        expect(chat_session.messages.find_by(role: "tool").tool_result).to eq({ "id" => 99, "status" => "queued" })
      end

      # @spec CHAT-TOOL-CONFIRMATION-002
      it "auto-approves reversible GitHub issue writes like filing a new issue" do
        allow(Tools::Registry).to receive(:dispatch).and_return({ "number" => 7, "url" => "https://example/7" })

        result = described_class.new(chat_session: chat_session, llm_client: issue_client).run

        expect(result).to be_present
        expect(Tools::Registry).to have_received(:dispatch).with(
          hash_including(
            name: "create_issue",
            arguments: hash_including("confirmed" => true, "title" => "Bug"),
            user: user,
            session: chat_session
          )
        )
        expect(chat_session.messages.where(tool_status: "pending")).not_to exist
        expect(chat_session.messages.find_by(tool_status: "approved").tool_name).to eq("create_issue")
      end

      it "still requires a manual confirmation for write tools outside the auto-approve allowlist" do
        allow(Tools::Registry).to receive(:post_dispatch_confirmation?).and_call_original
        allow(Tools::Registry).to receive(:post_dispatch_confirmation?).with("record_change_intent").and_return(true)
        allow(Tools::Registry).to receive_messages(
          dispatch: { "id" => 44, "status" => "draft" },
          resolve_confirmation: { "id" => 44, "status" => "active" }
        )

        result = described_class.new(chat_session: chat_session, llm_client: cir_client).run

        expect(result).to be_nil
        expect(Tools::Registry).not_to have_received(:resolve_confirmation)
        pending_message = chat_session.messages.find_by(tool_status: "pending")
        expect(pending_message.tool_name).to eq("record_change_intent")
        expect(pending_message.tool_result).to eq({ "id" => 44, "status" => "draft" })
      end

      it "leaves a post-dispatch tool pending when its auto-resolution returns an error" do
        allow(Tools::Registry).to receive(:post_dispatch_confirmation?).and_call_original
        allow(Tools::Registry).to receive(:post_dispatch_confirmation?).with("record_change_intent").and_return(true)
        allow(Tools::Registry).to receive_messages(
          dispatch: { "id" => 44, "status" => "draft" },
          resolve_confirmation: { "status" => "error", "error" => "internal_error", "message" => "boom" }
        )

        described_class.new(chat_session: chat_session, llm_client: cir_client).run

        pending_message = chat_session.messages.find_by(tool_status: "pending")
        expect(pending_message).to be_present
        expect(pending_message.tool_name).to eq("record_change_intent")
        expect(pending_message.tool_result).to include("status" => "draft")
        expect(chat_session.messages.where(tool_status: "approved")).not_to exist
      end

      # @spec CHAT-TOOL-CONFIRMATION-003
      it "surfaces malformed auto-approved tool calls as invalid arguments" do
        allow(Tools::Registry).to receive(:dispatch).and_call_original

        described_class.new(chat_session: chat_session, llm_client: malformed_auto_approve_client).run

        tool_result = chat_session.messages.find_by(role: "tool", tool_call_id: "call_1").tool_result
        expect(tool_result).to include(
          "status" => "error",
          "error" => "invalid_arguments",
          "message" => "Missing required argument: project_id"
        )
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

    context "when the iteration limit is reached" do
      let(:tool_response) do
        {
          content: nil,
          tool_calls: [ { id: "call_1", name: "search", arguments: { "query" => "test" } } ],
          tokens_input: 10, tokens_output: 5, model: "gpt-4o"
        }
      end
      let(:summary_response) do
        { content: "Here is a summary of what I found.", tool_calls: [], tokens_input: 20, tokens_output: 15, model: "gpt-4o" }
      end

      before do
        create(:tenant_setting, account: account,
          features: { "chat_settings" => { "chat_max_tool_iterations" => 2 } })
        allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user, session: anything).and_return(tool_definitions)
        allow(Tools::Registry).to receive(:dispatch).and_return({ "status" => "ok" })
      end

      it "injects the soft-stop prompt and calls the model without tools for the summary" do
        seen_without_tools = []
        client = Class.new do
          attr_reader :seen_conversations

          def initialize(responses, seen_without_tools)
            @responses = responses
            @seen_conversations = []
            @seen_without_tools = seen_without_tools
          end

          def call(conversation, tools: nil)
            @seen_conversations << conversation.deep_dup
            @seen_without_tools << conversation.deep_dup if tools.nil?
            @responses.fetch(@seen_conversations.length - 1)
          end
        end.new([ tool_response, tool_response, summary_response ], seen_without_tools)

        result = described_class.new(chat_session: chat_session, llm_client: client).run

        expect(result.content).to eq("Here is a summary of what I found.")
        expect(client.seen_conversations.length).to eq(3)
        expect(seen_without_tools.length).to eq(1)
        expect(seen_without_tools.first.last[:content]).to include("maximum number of tool calls")
        expect(chat_session.messages.where(role: "tool").count).to eq(2)
      end

      it "uses the fallback message when the soft-stop response is empty" do
        client = Class.new do
          def initialize(responses)
            @responses = responses
            @index = 0
          end

          def call(_conversation, tools: nil)
            @index += 1
            @responses.fetch(@index - 1)
          end
        end.new([ tool_response, tool_response, { content: nil, tool_calls: [], tokens_input: 5, tokens_output: 0, model: "gpt-4o" } ])

        result = described_class.new(chat_session: chat_session, llm_client: client).run

        expect(result.content).to eq(described_class::SOFT_STOP_FALLBACK_MESSAGE)
      end
    end

    context "when the token budget is exhausted mid-loop" do
      before do
        allow(Tools::Registry).to receive(:chat_definitions_for).with(user: user, session: anything).and_return(tool_definitions)
        allow(Tools::Registry).to receive(:dispatch).and_return({ "status" => "ok" })
      end

      it "triggers the soft-stop once usage exceeds the budget" do
        configure_session_token_limit(25)
        client = build_token_budget_client

        result = described_class.new(chat_session: chat_session, llm_client: client).run

        # Iteration 0: 15 tokens (10+5), under 25 → continue
        # Iteration 1: +15 = 30 tokens, 30 > 25 → soft-stop (3rd call)
        expect(result.content).to include("token budget")
        expect(client.seen_conversations.length).to eq(3)
        expect(client.seen_conversations.last.last[:content]).to include("token budget")
        expect(client.seen_conversations.last.last[:content]).not_to include("maximum number of tool calls")
        expect(chat_session.messages.where(role: "tool").count).to eq(1)
      end

      it "triggers the soft-stop when usage reaches the budget exactly (not only above)" do
        configure_session_token_limit(30)
        client = build_token_budget_client

        result = described_class.new(chat_session: chat_session, llm_client: client).run

        # Iteration 0: 15 tokens, under 30 → continue
        # Iteration 1: +15 = exactly 30 → soft-stop fires before the 2nd tool runs
        expect(result.content).to include("token budget")
        expect(client.seen_conversations.length).to eq(3)
        expect(chat_session.messages.where(role: "tool").count).to eq(1)
      end

      def configure_session_token_limit(limit)
        account.tenant_setting&.destroy
        create(:tenant_setting, account: account,
          features: { "chat_settings" => { "chat_session_token_limit" => limit } })
      end

      def build_token_budget_client
        Class.new do
          attr_reader :seen_conversations

          def initialize
            @seen_conversations = []
            @index = 0
          end

          def call(conversation, tools: nil)
            @seen_conversations << conversation.deep_dup
            @index += 1
            @index <= 2 ? tool_response : summary_response
          end

          private

          def tool_response
            {
              content: nil,
              tool_calls: [ { id: "call_#{@index}", name: "search", arguments: { "query" => "test" } } ],
              tokens_input: 10, tokens_output: 5, model: "gpt-4o"
            }
          end

          def summary_response
            { content: "I hit the token budget. Here is what I have so far.", tool_calls: [], tokens_input: 5, tokens_output: 10, model: "gpt-4o" }
          end
        end.new
      end
    end

    context "when the iteration limit is configurable via tenant settings" do
      it "defaults to DEFAULT_MAX_TOOL_ITERATIONS when no tenant setting exists" do
        service = described_class.new(chat_session: chat_session, llm_client: instance_double(Proc))

        expect(service.send(:max_tool_iterations)).to eq(described_class::DEFAULT_MAX_TOOL_ITERATIONS)
      end

      it "uses the tenant setting when configured" do
        create(:tenant_setting, account: account,
          features: { "chat_settings" => { "chat_max_tool_iterations" => 25 } })
        service = described_class.new(chat_session: chat_session, llm_client: instance_double(Proc))

        expect(service.send(:max_tool_iterations)).to eq(25)
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

  describe "#trim_conversation" do
    let(:service) { described_class.new(chat_session: chat_session, llm_client: instance_double(Proc)) }
    let(:cap) { described_class::MAX_CONVERSATION_MESSAGES }

    it "returns the conversation unchanged when at or under the cap" do
      conversation = Array.new(cap) { { role: "user", content: "x" } }

      trimmed = service.send(:trim_conversation, conversation)

      expect(trimmed.length).to eq(cap)
      expect(trimmed).to equal(conversation)
    end

    it "keeps only the most recent entries once the cap is exceeded" do
      conversation = Array.new(cap + 5) { |i| { role: "user", content: "m#{i}" } }

      trimmed = service.send(:trim_conversation, conversation)

      expect(trimmed.length).to eq(cap)
      expect(trimmed.first[:content]).to eq("m5")
      expect(trimmed.last[:content]).to eq("m#{cap + 4}")
    end

    it "drops leading tool entries so the window never starts with an orphaned tool result" do
      user_entry = { role: "user", content: "u" }
      tool_entry = { role: "tool", content: "r", tool_call_id: "c", tool_name: "search" }
      # cap + 1 entries; after taking the last `cap`, the first is a tool entry
      conversation = [ user_entry, tool_entry ] + Array.new(cap - 1) { user_entry }

      trimmed = service.send(:trim_conversation, conversation)

      expect(trimmed.length).to eq(cap - 1)
      expect(trimmed.first[:role]).to eq("user")
      expect(trimmed).not_to include(tool_entry)
    end

    it "preserves an assistant tool-call entry and its following tool results when they lead the window" do
      assistant_entry = {
        role: "assistant", content: "ok",
        tool_calls: [ { id: "c", name: "search", arguments: {} } ]
      }
      tool_entry = { role: "tool", content: "r", tool_call_id: "c", tool_name: "search" }
      user_entry = { role: "user", content: "u" }
      # One entry over the cap; the window starts at the assistant whose result follows
      conversation = [ user_entry, assistant_entry, tool_entry ] + Array.new(cap - 2) { user_entry }

      trimmed = service.send(:trim_conversation, conversation)

      expect(trimmed.length).to eq(cap)
      expect(trimmed.first).to eq(assistant_entry)
      expect(trimmed.second).to eq(tool_entry)
    end
  end
end
