# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ChatMessages" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  describe "GET /chat/:chat_session_id/messages" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get chat_session_chat_messages_path(chat_session)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns paginated messages" do
        create_list(:chat_message, 3, chat_session: chat_session, role: "user")
        create(:chat_message, :assistant, chat_session: chat_session)

        get chat_session_chat_messages_path(chat_session)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.length).to eq(4)
      end

      it "filters by role" do
        create(:chat_message, chat_session: chat_session, role: "user")
        create(:chat_message, :assistant, chat_session: chat_session)

        get chat_session_chat_messages_path(chat_session), params: { role: "user" }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.length).to eq(1)
        expect(response.parsed_body.first["role"]).to eq("user")
      end

      it "supports cursor pagination with before param" do
        messages = create_list(:chat_message, 3, chat_session: chat_session, role: "user")

        get chat_session_chat_messages_path(chat_session), params: { before: messages.last.id }
        expect(response).to have_http_status(:ok)
        ids = response.parsed_body.map { |m| m["id"] }
        expect(ids).not_to include(messages.last.id)
      end
    end
  end

  describe "POST /chat/:chat_session_id/messages" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post chat_session_chat_messages_path(chat_session), params: { content: "Hello" }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated with JSON response" do
      before { sign_in user }

      let(:llm_response) do
        { content: "Hello back!", model: "gpt-4o", tokens_input: 10, tokens_output: 5 }
      end

      it "creates a message and returns assistant response" do
        llm_client = instance_double(Proc)
        allow(ChatSessions::BuildLlmClient).to receive(:call).with(chat_session: chat_session).and_return(llm_client)
        allow(ChatSessions::SendMessage).to receive(:call).and_return(
          create(:chat_message, :assistant, chat_session: chat_session,
            content: "Hello back!", tokens_input: 10, tokens_output: 5)
        )

        post chat_session_chat_messages_path(chat_session), params: { content: "Hello" }
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["role"]).to eq("assistant")
        expect(response.parsed_body["content"]).to eq("Hello back!")
      end

      it "returns error when content is blank" do
        post chat_session_chat_messages_path(chat_session), params: { content: "" }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "persists the chat response and token usage through the controller path" do
        llm_client = instance_double(Proc, call: llm_response)
        allow(ChatSessions::BuildLlmClient).to receive(:call).with(chat_session: chat_session).and_return(llm_client)

        expect {
          post chat_session_chat_messages_path(chat_session), params: { content: "Hello" }
        }.to change { chat_session.messages.where(role: "assistant").count }.by(1)
          .and change { chat_session.token_usages.for_chat.count }.by(1)

        expect(response).to have_http_status(:created)
        expect(chat_session.token_usages.for_chat.order(:id).last).to have_attributes(
          input_tokens: 10,
          output_tokens: 5,
          llm_model: "gpt-4o",
          request_type: "chat_message"
        )
      end

      it "returns a clear setup error when no chat runner is configured" do
        allow(ChatSessions::BuildLlmClient).to receive(:call)
          .with(chat_session: chat_session)
          .and_raise(
            ChatSessions::LlmClientConfigurationError,
            "Chat requires a configured API-key runner. Add a chat-enabled runner with an API key and select it for this session."
          )

        post chat_session_chat_messages_path(chat_session), params: { content: "Hello" }

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body).to eq(
          "error" => "Chat requires a configured API-key runner. Add a chat-enabled runner with an API key and select it for this session."
        )
      end
    end

    context "when authenticated with SSE response" do
      before { sign_in user }

      it "returns SSE stream" do
        assistant_msg = create(:chat_message, :assistant, chat_session: chat_session,
          tokens_input: 10, tokens_output: 5)
        llm_client = instance_double(Proc)
        allow(ChatSessions::BuildLlmClient).to receive(:call).with(chat_session: chat_session).and_return(llm_client)
        allow(ChatSessions::SendMessage).to receive(:call) do |**args|
          args[:on_chunk].call("Hello ")
          args[:on_chunk].call("back!")
          assistant_msg
        end

        post chat_session_chat_messages_path(chat_session),
          params: { content: "Hello" },
          headers: { "Accept" => "text/event-stream" }

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Type"]).to include("text/event-stream")

        body = response.body
        expect(body).to include("event: message_start")
        expect(body).to include("event: message_chunk")
        expect(body).to include("event: message_complete")
      end

      it "emits message_tool_call event when a tool call message is persisted" do
        assistant_msg = create(:chat_message, :assistant, chat_session: chat_session, tokens_input: 10, tokens_output: 5)
        tool_call_msg = create(:chat_message, :tool_call, chat_session: chat_session,
          tool_call_id: "call_abc", tool_name: "search", tool_arguments: { query: "test" })
        stream_id = SecureRandom.uuid
        allow(ChatSessions::BuildLlmClient).to receive(:call).and_return(instance_double(Proc))
        allow(ChatSessions::SendMessage).to receive(:call) do |**args|
          args[:on_message_persisted].call(tool_call_msg, stream_message_id: stream_id)
          assistant_msg
        end

        post chat_session_chat_messages_path(chat_session),
          params: { content: "Hello" }, headers: { "Accept" => "text/event-stream" }

        data = JSON.parse(response.body.scan(/event: message_tool_call\ndata: (.+)\n/).flatten.first)
        expect(data).to include("tool_name" => "search", "tool_call_id" => "call_abc",
          "role" => "assistant", "stream_message_id" => stream_id)
      end

      it "emits message_tool_result event when a tool result message is persisted" do
        assistant_msg = create(:chat_message, :assistant, chat_session: chat_session, tokens_input: 10, tokens_output: 5)
        tool_result_msg = create(:chat_message, :tool, chat_session: chat_session,
          tool_call_id: "call_abc", tool_name: "search", tool_result: { results: [ "item" ] })
        stream_id = SecureRandom.uuid
        allow(ChatSessions::BuildLlmClient).to receive(:call).and_return(instance_double(Proc))
        allow(ChatSessions::SendMessage).to receive(:call) do |**args|
          args[:on_message_persisted].call(tool_result_msg, stream_message_id: stream_id)
          assistant_msg
        end

        post chat_session_chat_messages_path(chat_session),
          params: { content: "Hello" }, headers: { "Accept" => "text/event-stream" }

        data = JSON.parse(response.body.scan(/event: message_tool_result\ndata: (.+)\n/).flatten.first)
        expect(data).to include("tool_name" => "search", "tool_call_id" => "call_abc",
          "role" => "tool", "tool_result" => { "results" => [ "item" ] }, "stream_message_id" => stream_id)
      end

      it "does not emit tool events for regular user or assistant messages" do
        assistant_msg = create(:chat_message, :assistant, chat_session: chat_session,
          tokens_input: 10, tokens_output: 5)
        user_msg = create(:chat_message, chat_session: chat_session)
        llm_client = instance_double(Proc)
        allow(ChatSessions::BuildLlmClient).to receive(:call).with(chat_session: chat_session).and_return(llm_client)
        allow(ChatSessions::SendMessage).to receive(:call) do |**args|
          args[:on_message_persisted].call(user_msg)
          args[:on_message_persisted].call(assistant_msg)
          assistant_msg
        end

        post chat_session_chat_messages_path(chat_session),
          params: { content: "Hello" },
          headers: { "Accept" => "text/event-stream" }

        body = response.body
        expect(body).not_to include("event: message_tool_call")
        expect(body).not_to include("event: message_tool_result")
      end

      it "emits message_tool_confirmation for a pending write tool call" do
        pending_msg = create(:chat_message, :tool_call, chat_session: chat_session,
          tool_call_id: "call_xyz", tool_name: "trigger_agent_run",
          tool_arguments: { "project_id" => 1 }, tool_status: "pending")
        allow(ChatSessions::BuildLlmClient).to receive(:call).and_return(instance_double(Proc))
        allow(ChatSessions::SendMessage).to receive(:call) do |**args|
          args[:on_message_persisted].call(pending_msg)
          nil
        end

        post chat_session_chat_messages_path(chat_session),
          params: { content: "Run it" }, headers: { "Accept" => "text/event-stream" }

        data = JSON.parse(response.body.scan(/event: message_tool_confirmation\ndata: (.+)\n/).flatten.first)
        expect(data).to include("tool_name" => "trigger_agent_run", "tool_status" => "pending")
      end
    end
  end

  describe "POST /chat/:chat_session_id/messages/:id/resolve" do
    let(:pending_message) do
      create(:chat_message, :tool_call, chat_session: chat_session,
        tool_call_id: "call_xyz", tool_name: "update_user_settings",
        tool_arguments: { "settings" => {} }, tool_status: "pending")
    end

    context "when not authenticated" do
      it "redirects to the sign in page" do
        post resolve_chat_session_chat_message_path(chat_session, pending_message),
          params: { decision: "approve" }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated with JSON response" do
      before { sign_in user }

      it "resolves an approved tool call and returns the resumed assistant message" do
        assistant_msg = create(:chat_message, :assistant, chat_session: chat_session, content: "Done.")
        allow(ChatSessions::BuildLlmClient).to receive(:call).and_return(instance_double(Proc))
        allow(ChatSessions::ResolveToolCall).to receive(:call).and_return(assistant_msg)

        post resolve_chat_session_chat_message_path(chat_session, pending_message),
          params: { decision: "approve" }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["content"]).to eq("Done.")
        expect(ChatSessions::ResolveToolCall).to have_received(:call).with(
          hash_including(decision: "approve", tool_call_message: pending_message)
        )
      end

      it "returns a paused status when the resumed loop awaits another confirmation" do
        allow(ChatSessions::BuildLlmClient).to receive(:call).and_return(instance_double(Proc))
        allow(ChatSessions::ResolveToolCall).to receive(:call).and_return(nil)

        post resolve_chat_session_chat_message_path(chat_session, pending_message),
          params: { decision: "deny" }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq("status" => "paused")
      end

      it "rejects an invalid decision" do
        post resolve_chat_session_chat_message_path(chat_session, pending_message),
          params: { decision: "maybe" }

        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "when authenticated with SSE response" do
      before { sign_in user }

      it "emits a message_tool_resolved event and the resumed stream" do
        assistant_msg = create(:chat_message, :assistant, chat_session: chat_session, tokens_input: 10, tokens_output: 5)
        allow(ChatSessions::BuildLlmClient).to receive(:call).and_return(instance_double(Proc))
        allow(ChatSessions::ResolveToolCall).to receive(:call) do |**args|
          args[:on_tool_call_resolved].call(pending_message)
          args[:on_chunk]&.call("Done.")
          assistant_msg
        end

        post resolve_chat_session_chat_message_path(chat_session, pending_message),
          params: { decision: "approve" }, headers: { "Accept" => "text/event-stream" }

        expect(response).to have_http_status(:ok)
        body = response.body
        expect(body).to include("event: message_tool_resolved")
        expect(body).to include("event: message_chunk")
        expect(body).to include("event: message_complete")
      end
    end
  end
end
