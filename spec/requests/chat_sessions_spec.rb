# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ChatSessions" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /chat" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get chat_sessions_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "lists chat sessions ordered by updated_at desc" do
        old_session = create(:chat_session, account: account, created_by: user, updated_at: 1.day.ago)
        new_session = create(:chat_session, account: account, created_by: user, updated_at: 1.hour.ago)

        get chat_sessions_path(format: :json)
        expect(response).to have_http_status(:ok)

        body = response.parsed_body
        expect(body["sessions"].length).to eq(2)
        expect(body["sessions"].first["id"]).to eq(new_session.id)
        expect(body["sessions"].last["id"]).to eq(old_session.id)
        expect(body["pagination"]).to include("page", "pages", "count")
      end

      it "does not include sessions from other accounts" do
        other_account = create(:account)
        create(:chat_session, account: other_account)
        create(:chat_session, account: account, created_by: user)

        get chat_sessions_path(format: :json)
        expect(response.parsed_body["sessions"].length).to eq(1)
      end

      it "paginates sessions" do
        26.times do |index|
          create(:chat_session, account: account, created_by: user, updated_at: index.minutes.ago)
        end

        get chat_sessions_path(format: :json)
        expect(response).to have_http_status(:ok)

        body = response.parsed_body
        expect(body["sessions"].length).to eq(25)
        expect(body["pagination"]).to include("page" => 1, "pages" => 2, "count" => 26)
      end

      it "renders the chat index page for html requests" do
        create(:chat_session, account: account, created_by: user, title: "Planning Thread")

        get chat_sessions_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Interactive Chat")
        expect(response.body).to include("Planning Thread")
      end
    end
  end

  describe "POST /chat" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post chat_sessions_path, params: { mode: "api" }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "creates a new chat session" do
        expect {
          post chat_sessions_path(format: :json), params: { mode: "api", title: "Test Chat" }
        }.to change(ChatSession, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["title"]).to eq("Test Chat")
        expect(body["status"]).to eq("active")
        expect(body["mode"]).to eq("api")
        expect(body["external_id"]).to be_present
      end

      it "creates a session with default mode" do
        post chat_sessions_path(format: :json)
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["mode"]).to eq("api")
      end

      it "redirects to the session page for html requests" do
        post chat_sessions_path, params: { mode: "api", title: "UI Chat" }

        expect(response).to redirect_to(chat_session_path(ChatSession.last))
      end
    end
  end

  describe "GET /chat/:id" do
    let!(:chat_session) { create(:chat_session, account: account, created_by: user) }

    context "when not authenticated" do
      it "redirects to the sign in page" do
        get chat_session_path(chat_session)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns session detail with messages" do
        create(:chat_message, chat_session: chat_session, role: "user", content: "Hello")
        create(:chat_message, :assistant, chat_session: chat_session)

        get chat_session_path(chat_session, format: :json)
        expect(response).to have_http_status(:ok)

        body = response.parsed_body
        expect(body["id"]).to eq(chat_session.id)
        expect(body["messages"].length).to eq(2)
        expect(body["pagination"]).to include("page", "pages", "count")
      end

      it "returns structured tool payloads in the JSON API" do
        create(:chat_message, :tool_call, chat_session: chat_session, tool_call_id: "call_1")
        create(:chat_message, :tool, chat_session: chat_session, tool_call_id: "call_1", tool_result: { status: "ok" })

        get chat_session_path(chat_session, format: :json)

        tool_call = response.parsed_body["messages"].find { |message| message["role"] == "assistant" && message["tool_name"] == "search" }
        tool_result = response.parsed_body["messages"].find { |message| message["role"] == "tool" }

        expect(tool_call["tool_arguments"]).to eq({ "query" => "test" })
        expect(tool_result["tool_result"]).to eq({ "status" => "ok" })
      end

      it "does not return another account's session" do
        other_account = create(:account)
        other_session = create(:chat_session, account: other_account)

        get chat_session_path(other_session, format: :json)
        expect(response).to have_http_status(:not_found)
      end

      it "renders the interactive chat page for html requests" do
        create(:chat_message, :assistant, chat_session: chat_session, content: "Rendered markdown")

        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Assistant is typing")
        expect(response.body).to include("Rendered markdown")
      end
    end
  end

  describe "GET /chat/:id/older_messages" do
    let!(:chat_session) { create(:chat_session, account: account, created_by: user) }

    context "when authenticated" do
      before { sign_in user }

      it "renders the requesting turbo frame id for paginated fetches" do
        52.times { |index| create(:chat_message, chat_session: chat_session, content: "Message #{index}") }
        newest_message = create(:chat_message, chat_session: chat_session, content: "Newest message")

        get older_messages_chat_session_path(chat_session),
          params: { before: newest_message.id },
          headers: { "Turbo-Frame" => "older_messages_next" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to match(/<turbo-frame[^>]*id="older_messages_next"/)
        expect(response.body).to match(/<turbo-frame[^>]*id="older_messages_next_next"/)
      end
    end
  end

  describe "PATCH /chat/:id" do
    let!(:chat_session) { create(:chat_session, account: account, created_by: user) }

    context "when authenticated" do
      before { sign_in user }

      it "updates the session title" do
        patch chat_session_path(chat_session, format: :json), params: { title: "Updated Title" }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["title"]).to eq("Updated Title")
        expect(chat_session.reload.title).to eq("Updated Title")
      end

      it "updates the model" do
        patch chat_session_path(chat_session, format: :json), params: { model: "gpt-4o" }
        expect(response).to have_http_status(:ok)
        expect(chat_session.reload.model).to eq("gpt-4o")
      end

      it "updates values submitted under chat_session params" do
        patch chat_session_path(chat_session), params: { chat_session: { title: "Updated From Form", model: "gpt-4.1" } }

        expect(response).to redirect_to(chat_session_path(chat_session))
        expect(chat_session.reload.title).to eq("Updated From Form")
        expect(chat_session.model).to eq("gpt-4.1")
      end
    end
  end

  describe "DELETE /chat/:id" do
    let!(:chat_session) { create(:chat_session, account: account, created_by: user) }

    context "when authenticated" do
      before { sign_in user }

      it "closes the session and returns 204" do
        delete chat_session_path(chat_session, format: :json)
        expect(response).to have_http_status(:no_content)
        expect(chat_session.reload.status).to eq("closed")
      end
    end
  end
end
