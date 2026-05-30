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

      it "redirects to existing active session for html requests" do
        existing = create(:chat_session, account: account, created_by: user, status: "active")

        expect {
          get chat_sessions_path
        }.not_to change(ChatSession, :count)

        expect(response).to redirect_to(chat_session_path(existing))
      end

      it "auto-creates a new session when no active sessions exist" do
        existing_ids = ChatSession.pluck(:id)

        expect {
          get chat_sessions_path
        }.to change(ChatSession, :count).by(1)

        created_session = ChatSession.where.not(id: existing_ids).sole
        expect(response).to redirect_to(chat_session_path(created_session))
      end

      it "defaults wildcard accept requests to the existing json API" do
        create(:chat_session, account: account, created_by: user, title: "API Session")

        get chat_sessions_path, headers: { "Accept" => "*/*" }

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/json")
        expect(response.parsed_body["sessions"].first["title"]).to eq("API Session")
      end
    end

    context "when authenticated as a viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before { sign_in viewer }

      it "hides new-session controls" do
        get chat_sessions_path

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("New Chat")
        expect(response.body).not_to include("Create session")
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

      it "creates a session with popup metadata context" do
        post chat_sessions_path(format: :json), params: {
          mode: "api",
          project_id: create(:project, account: account).id,
          metadata: {
            entry_point: "popup",
            page_context: {
              url: "https://paid.example.test/projects/3",
              page_title: "Acme API - Projects - Paid",
              project_name: "Acme API"
            }
          }
        }

        expect(response).to have_http_status(:created)
        expect(ChatSession.order(:id).last.metadata).to include(
          "entry_point" => "popup",
          "page_context" => include("project_name" => "Acme API")
        )
      end

      it "accepts provider_id as a legacy alias for runner_id" do
        runner = create(:runner, user: user)

        post chat_sessions_path(format: :json), params: { mode: "api", provider_id: runner.id }

        expect(response).to have_http_status(:created)
        expect(ChatSession.order(:id).last.runner).to eq(runner)
      end

      it "redirects to the session page for html requests" do
        existing_ids = ChatSession.pluck(:id)

        post chat_sessions_path, params: { mode: "api", title: "UI Chat" }

        created_session = ChatSession.where.not(id: existing_ids).sole
        expect(response).to redirect_to(chat_session_path(created_session))
      end

      it "defaults wildcard accept create requests to json" do
        post chat_sessions_path, params: { mode: "api", title: "API Chat" }, headers: { "Accept" => "*/*" }

        expect(response).to have_http_status(:created)
        expect(response.media_type).to eq("application/json")
        expect(response.parsed_body["title"]).to eq("API Chat")
      end

      it "returns an html response when the create rate limit is exceeded" do
        Rails.cache.clear

        10.times do |index|
          post chat_sessions_path, params: { mode: "api", title: "Chat #{index}" }
        end

        post chat_sessions_path, params: { mode: "api", title: "Blocked chat" }

        expect(response).to redirect_to(chat_sessions_path)
        expect(flash[:alert]).to eq("Rate limit exceeded")
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

      it "renders the popup variant for embedded requests" do
        chat_session.update!(
          metadata: {
            "page_context" => {
              "page_title" => "Projects - Paid",
              "project_name" => "Acme API"
            }
          }
        )

        get chat_session_path(chat_session), params: { display: "popup" }, headers: { "Accept" => "text/html" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Support chat")
        expect(response.body).to include("New Chat")
        expect(response.body).to include("Open page")
        expect(response.body).to include("Projects - Paid")
      end

      it "renders mobile archive controls without expanding the sidebar by default" do
        get chat_session_path(chat_session)

        expect(response).to have_http_status(:ok)
        doc = Nokogiri::HTML(response.body)
        mobile_toggle = doc.at_css("button[data-chat-session-list-target='mobileButton']")
        sidebar = doc.at_css("#chat-sessions-sidebar[data-chat-session-list-target='mobileMenu']")

        expect(mobile_toggle).to be_present
        expect(mobile_toggle.text).to include("Previous chats")
        expect(sidebar).to be_present
        expect(sidebar["aria-hidden"]).to eq("true")
        expect(sidebar["class"].split).to include("hidden", "lg:block")
      end

      it "defaults wildcard accept show requests to the existing json API" do
        create(:chat_message, chat_session: chat_session, role: "user", content: "Hello")

        get chat_session_path(chat_session), headers: { "Accept" => "*/*" }

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/json")
        expect(response.parsed_body["id"]).to eq(chat_session.id)
      end

      it "loads the newest 50 messages on the initial html render" do
        101.times { |index| create(:chat_message, chat_session: chat_session, content: "Message #{index}") }

        get chat_session_path(chat_session)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Message 100")
        expect(response.body).to include("Message 51")
        expect(response.body).not_to include("Message 50")
      end

      it "pins the active session in the sidebar when it falls outside the first batch" do
        chat_session.update_columns(title: "Pinned session", updated_at: 3.days.ago)

        55.times do |index|
          create(:chat_session, account: account, created_by: user, title: "Recent #{index}", updated_at: index.minutes.ago)
        end

        get chat_session_path(chat_session)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(data-session-id="#{chat_session.id}"))
      end
    end

    context "when authenticated as a viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before { sign_in viewer }

      it "renders a read-only chat view" do
        get chat_session_path(chat_session)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("You have read-only access to this chat.")
        expect(response.body).not_to include(%(name="chat_session[title]"))
        expect(response.body).not_to include(%(name="chat_session[runner_id]"))
        expect(response.body).not_to include(%(name="chat_session[model]"))
        expect(response.body).not_to include(%(name="content"))
        expect(response.body).not_to include("New Chat")
      end

      it "does not render popup new-chat controls" do
        get chat_session_path(chat_session), params: { display: "popup" }, headers: { "Accept" => "text/html" }

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("New Chat")
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

  describe "GET /chat/sidebar_page" do
    before { sign_in user }

    it "paginates with a stable updated_at/id cursor" do
      sessions = 55.times.map do |index|
        create(:chat_session, account: account, created_by: user, title: "Session #{index}", updated_at: index.minutes.ago)
      end
      cursor_session = sessions[49]

      get sidebar_page_chat_sessions_path,
        params: {
          before_updated_at: cursor_session.updated_at.iso8601(6),
          before_id: cursor_session.id
        },
        headers: { "Turbo-Frame" => "sidebar_page_#{cursor_session.id}" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Session 50")
      expect(response.body).to include("Session 54")
      expect(response.body).not_to include("Session 49")
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

      it "updates popup metadata context" do
        patch chat_session_path(chat_session, format: :json), params: {
          metadata: {
            entry_point: "popup",
            page_context: {
              url: "https://paid.example.test/projects/9/quality",
              page_title: "Quality Metrics - Acme API - Paid",
              project_name: "Acme API"
            }
          }
        }

        expect(response).to have_http_status(:ok)
        expect(chat_session.reload.metadata).to include(
          "page_context" => include(
            "url" => "https://paid.example.test/projects/9/quality",
            "project_name" => "Acme API"
          )
        )
      end
    end
  end

  describe "DELETE /chat/:id" do
    let!(:chat_session) { create(:chat_session, account: account, created_by: user) }

    context "when authenticated" do
      before { sign_in user }

      it "closes the session and returns 204" do
        create(:chat_message, chat_session: chat_session)
        delete chat_session_path(chat_session, format: :json)
        expect(response).to have_http_status(:no_content)
        expect(chat_session.reload.status).to eq("closed")
      end
    end
  end
end
