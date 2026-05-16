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
    end

    context "when authenticated with SSE response" do
      before { sign_in user }

      it "returns SSE stream" do
        assistant_msg = create(:chat_message, :assistant, chat_session: chat_session,
          tokens_input: 10, tokens_output: 5)
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
    end
  end
end
