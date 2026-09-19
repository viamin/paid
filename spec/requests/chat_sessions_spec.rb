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
        # @spec CHAT-API-005
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

      it "does not include archived sessions in the default listing" do
        visible = create(:chat_session, account: account, created_by: user, title: "Visible")
        create(:chat_session, :archived, account: account, created_by: user, title: "Archived")

        get chat_sessions_path(format: :json)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["sessions"].map { |session| session["id"] }).to eq([ visible.id ])
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
        post chat_sessions_path, params: { container_capability: "none" }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "creates a new chat session" do
        expect {
          post chat_sessions_path(format: :json), params: { container_capability: "none", title: "Test Chat" }
        }.to change(ChatSession, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["title"]).to eq("Test Chat")
        expect(body["status"]).to eq("active")
        expect(body["container_capability"]).to eq("none")
        expect(body["external_id"]).to be_present
      end

      it "creates a session with default container capability" do
        # @spec CHAT-API-001
        post chat_sessions_path(format: :json)
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["container_capability"]).to eq("none")
      end

      it "maps legacy api mode to inline-only sessions" do
        # @spec CHAT-API-001
        post chat_sessions_path(format: :json), params: { mode: "api", title: "Legacy API Chat" }

        expect(response).to have_http_status(:created)
        expect(response.parsed_body["container_capability"]).to eq("none")
      end

      it "maps legacy workspace mode to pending container capability" do
        # @spec CHAT-API-001
        post chat_sessions_path(format: :json), params: { mode: "workspace", title: "Legacy Workspace Chat" }

        expect(response).to have_http_status(:created)
        expect(response.parsed_body["container_capability"]).to eq("pending")
      end

      it "maps nested legacy workspace mode to pending container capability" do
        post chat_sessions_path(format: :json), params: { chat_session: { mode: "workspace", title: "Nested Legacy Workspace Chat" } }

        expect(response).to have_http_status(:created)
        expect(response.parsed_body["container_capability"]).to eq("pending")
      end

      it "rejects unsupported legacy modes" do
        post chat_sessions_path(format: :json), params: { mode: "desktop" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to eq("mode must be one of api, workspace")
      end

      it "prefers explicit container capability over legacy mode" do
        post chat_sessions_path(format: :json), params: { mode: "workspace", container_capability: "none" }

        expect(response).to have_http_status(:created)
        expect(response.parsed_body["container_capability"]).to eq("none")
      end

      it "rejects lifecycle-only container capabilities at creation time" do
        post chat_sessions_path(format: :json), params: { container_capability: "ready" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to include("container_capability")
      end

      it "creates a session with auto-approve enabled" do
        post chat_sessions_path(format: :json), params: { container_capability: "none", auto_approve: "true" }

        expect(response).to have_http_status(:created)
        expect(response.parsed_body["auto_approve"]).to be(true)
        expect(ChatSession.order(:id).last).to be_auto_approve
      end

      it "creates a session with popup metadata context" do
        post chat_sessions_path(format: :json), params: {
          container_capability: "none",
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
        runner = create_api_chat_runner

        post chat_sessions_path(format: :json), params: { container_capability: "none", provider_id: runner.id }

        expect(response).to have_http_status(:created)
        expect(ChatSession.order(:id).last.runner).to eq(runner)
      end

      it "rejects inline sessions with non-API chat runners" do
        runner = create(:runner, user: user, runner_key: "codex", auth_type: "subscription", enabled_for_chat: true)

        post chat_sessions_path(format: :json), params: { container_capability: "none", runner_id: runner.id }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to include("API-key chat runner")
      end

      it "redirects to the session page for html requests" do
        existing_ids = ChatSession.pluck(:id)

        post chat_sessions_path, params: { container_capability: "none", title: "UI Chat" }

        created_session = ChatSession.where.not(id: existing_ids).sole
        expect(response).to redirect_to(chat_session_path(created_session))
      end

      it "defaults wildcard accept create requests to json" do
        post chat_sessions_path, params: { container_capability: "none", title: "API Chat" }, headers: { "Accept" => "*/*" }

        expect(response).to have_http_status(:created)
        expect(response.media_type).to eq("application/json")
        expect(response.parsed_body["title"]).to eq("API Chat")
      end

      it "returns an html response when the create rate limit is exceeded" do
        Rails.cache.clear

        10.times do |index|
          post chat_sessions_path, params: { container_capability: "none", title: "Chat #{index}" }
        end

        post chat_sessions_path, params: { container_capability: "none", title: "Blocked chat" }

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
        # @spec CHAT-API-001
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

        doc = Nokogiri::HTML(response.body)
        # Keep a regression check for #2928 even though the destructive Close control
        # was already removed from the template before this branch was cut.
        token_usage_bar = doc.at_xpath("//p[normalize-space(text())='Token usage']/ancestor::div[contains(@class, 'bg-gray-900')]")

        expect(token_usage_bar).to be_present
        expect(token_usage_bar.text).to include("Archive")

        close_form = doc.at_xpath(
          "//form[@action='#{chat_session_path(chat_session)}'][.//input[@name='_method' and @value='delete']]"
        )

        expect(close_form).to be_nil
      end

      it "autosaves both chat runner and model selectors with visible status" do
        # @spec CHAT-SESSION-PREFERENCES-002
        get chat_session_path(chat_session)

        doc = Nokogiri::HTML(response.body)
        forms = doc.xpath("//form[@action='#{chat_session_path(chat_session)}'][.//select[@name='chat_session[runner_id]']][.//select[@name='chat_session[model]']]")

        expect(forms.size).to eq(2)
        forms.each do |form|
          expect(form.at_xpath(".//input[@type='submit']")).to be_nil
          expect(form.at_xpath(".//*[@data-chat-settings-status]")).to be_present
          expect(form["data-action"]).to include("change->chat#saveSettings")
          expect(form["data-action"]).to include("turbo:submit-end->chat#settingsSubmitted")
        end
      end

      it "hides saved assistant reasoning from the visible transcript" do
        # @spec CHAT-API-016
        create(:chat_message, :assistant, chat_session: chat_session,
          content: "<think>private reasoning</think>\n\nVisible answer")

        get chat_session_path(chat_session)

        transcript = Nokogiri::HTML(response.body).at_css(".chat-markdown")
        expect(transcript.text).to include("Visible answer")
        expect(transcript.text).not_to include("private reasoning", "<think>")
        expect(transcript["data-raw-content"]).to eq("Visible answer")
      end

      it "renders a persisted token-limit rejection visibly, without collapsing it into the system-prompt disclosure" do
        # @spec CHAT-API-014
        create(:chat_message, :system, chat_session: chat_session, content: "You are a helpful assistant.")
        create(:chat_message, chat_session: chat_session,
          content: "Session chat token limit reached.\n\nUsed 5,193,598 of 5,000,000 tokens allowed.\n\nStart a new chat session to continue, or ask an administrator to increase the configured session token limit.",
          role: "system",
          metadata: { "token_limit_error" => true, "limit_type" => "session", "limit" => 5_000_000, "used_tokens" => 5_193_598 })

        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)

        doc = Nokogiri::HTML(response.body)
        # Not tucked behind the collapsible "System prompt" <summary> — it must
        # be readable without expanding anything, and survive a reload (#3847).
        expect(doc.at_xpath("//summary[contains(., 'Token limit reached')]")).to be_nil
        expect(response.body).to include("Token limit reached")
        expect(response.body).to include("Used 5,193,598 of 5,000,000 tokens allowed")
        expect(response.body).to include("Start a new chat session to continue")
      end

      it "gives the conversation's scroll wrapper a min-h-0 flex constraint (#3331)" do
        # Without `min-h-0` on this flex-1 wrapper, WebKit lets it grow to fit
        # its content instead of clamping to the available space, so the
        # conversation partial's internal overflow-y-auto region never
        # actually scrolls (the whole page scrolls instead). That breaks both
        # the "jump to input" link and the "back to top" button on Safari,
        # since chat_controller's handleScroll/scrollToInput act on
        # containerTarget.scrollTop, which never changes when the page
        # scrolls instead of the intended container.
        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)

        doc = Nokogiri::HTML(response.body)
        wrapper = doc.at_xpath("//div[contains(@class, 'flex-1') and .//button[@data-action='click->chat#scrollToInput']]")

        expect(wrapper).to be_present
        expect(wrapper["class"].split.sort).to include("min-h-0")
      end

      it "height-bounds the chat panel so the conversation container is the scroll container (#3459, #3635)" do
        # @spec CHAT-API-008, CHAT-API-009
        # The #3331 fix added `min-h-0` to the inner flex-1 wrapper, but the
        # chat panel's outer wrapper still used `min-h-[70vh]` — a *minimum*,
        # not a bound. When the transcript is long the panel grows beyond the
        # viewport, the inner `overflow-y-auto` region expands to fit its
        # content, and the document scrolls instead. That leaves the
        # chat controller's scrollToInput / scrollToTop / handleScroll
        # writing to a scrollTop that never changes, so the "jump to input"
        # link does nothing and the floating "back to top" button never
        # appears. Mirror the popup's behavior with a viewport-bound height
        # (dvh so the iOS URL bar doesn't break it).
        #
        # The `--chat-panel-bottom-space` subtraction tracks the page's actual
        # bottom padding per breakpoint (1rem below `lg`, 2rem at `lg`+); the
        # static 2rem used to clamp 16px of mobile panel out and starve the
        # transcript (#3635).
        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)

        doc = Nokogiri::HTML(response.body)
        panel = doc.at_xpath("//div[@data-controller='chat']")

        expect(panel).to be_present
        # Anchored so a `max-height:` declaration cannot satisfy it by substring.
        expect(panel["style"]).to match(
          /(?:\A|;\s*)height: calc\(100dvh - var\(--chat-panel-offset-top, 0px\) - var\(--chat-panel-bottom-space, 2rem\)\)/
        )
      end

      it "uses a definite height rather than a max-height so the conversation's h-full root resolves" do
        # @spec CHAT-API-008
        # A `max-height` cap leaves the panel's own `height` computed as
        # `auto`, i.e. *indefinite*. Percentage heights below an indefinite
        # ancestor do not resolve, so the shared conversation partial's
        # `h-full` root fell back to its natural content height, overflowed
        # the `min-h-0 flex-1 overflow-hidden` wrapper, and got clipped —
        # the transcript cut off mid-conversation, the message input
        # unreachable, and nothing scrollable anywhere. A definite `height`
        # makes the flex chain definite so `h-full` resolves and the inner
        # container is the scroll region.
        #
        # The `70vh` floor must stay gone: against a definite height a
        # `min-height` can only clamp the panel *taller* than the viewport it
        # was just fitted to, which is the document-scroll failure mode
        # CHAT-API-008 exists to prevent.
        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)

        doc = Nokogiri::HTML(response.body)
        panel = doc.at_xpath("//div[@data-controller='chat']")

        expect(panel).to be_present
        expect(panel["style"]).not_to include("max-height")
        expect(panel["class"].split).not_to include("min-h-[70vh]", "lg:min-h-[70vh]")
      end

      it "collapses the desktop workspace disclosure for an inline-only chat" do
        # @spec CHAT-API-009
        # The capability panel's cloned-repo list grows without bound. Inside
        # a viewport-bound panel an unbounded header starves the transcript,
        # so an inline-only chat — which has no workspace to act on — folds it
        # away and gives the space to the message list.
        chat_session.update!(container_capability: "none")

        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)

        disclosure = desktop_workspace_disclosure_in(response.body)

        expect(disclosure).to be_present
        expect(disclosure["open"]).to be_nil
        expect(disclosure.at_xpath(".//summary")&.text).to include("Workspace")
      end

      it "renders the desktop workspace disclosure open when the chat has a workspace" do
        # @spec CHAT-API-009
        # A stopped workspace's only recovery path is the "Reopen with
        # workspace" button inside this panel. Folded away, the chat looks
        # unrecoverable — so the wide/desktop header renders the disclosure
        # open, in the server response, so it does not depend on JavaScript
        # having booted.
        %w[pending provisioning ready failed stopped].each do |capability|
          chat_session.update!(container_capability: capability)

          get chat_session_path(chat_session)
          expect(response).to have_http_status(:ok)

          disclosure = desktop_workspace_disclosure_in(response.body)

          expect(disclosure).to be_present, "no workspace disclosure for #{capability}"
          expect(disclosure["open"]).not_to be_nil, "workspace disclosure folded shut for #{capability}"
        end
      end

      it "uses a compact mobile page header so the transcript remains usable" do
        # @spec CHAT-API-009
        # On mobile the desktop header stack is too tall to coexist with the
        # viewport-bound panel, navbar, history toggle, and composer. Render a
        # separate compact header below `xl` and keep the transcript-dominating
        # desktop header out of that layout entirely.
        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)

        doc = Nokogiri::HTML(response.body)
        headers = doc.xpath("//div[@data-controller='chat']/header")

        expect(headers.size).to eq(2)

        mobile_header = headers.first
        desktop_header = headers.last

        expect(mobile_header["class"].split).to include("xl:hidden")
        expect(mobile_header.text).to include("Session details")
        expect(mobile_header.text).to include("Workspace")

        # @spec CHAT-API-009
        # Workspace chats render their outer disclosure open so recovery
        # controls do not depend on JavaScript, but its mobile body needs
        # compact spacing to preserve the transcript's 18rem floor.
        mobile_capability_panel = mobile_header.at_css("[data-chat-target='capabilityPanel']")
        expect(mobile_capability_panel["class"].split).to include("p-3", "sm:p-4")
        expect(mobile_capability_panel.at_css("[data-chat-capability-ready-only='true']")["class"].split).to include("mt-2", "sm:mt-4")

        expect(desktop_header["class"].split).to include("hidden", "xl:block")
      end

      it "collapses the desktop session-details disclosure by default so the chat stays chat-first" do
        # @spec CHAT-API-009
        # #3925: the always-visible desktop chrome is a single compact line
        # (title + "Session details" toggle). All session settings sit inside
        # a <details> closed by default. No `max-h-[45%]` cap is needed
        # because the always-visible chrome is a single compact line by
        # design; opening the disclosure is the user's choice and lets the
        # header grow for as long as the user keeps it open.
        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)

        doc = Nokogiri::HTML(response.body)
        header = desktop_header_in(doc)

        expect(header).to be_present

        classes = header["class"].split
        expect(classes).not_to include("max-h-[45%]", "has-[details[open]]:max-h-[75%]", "overflow-y-auto")

        disclosure = header.at_xpath(".//details[summary[contains(., 'Session details')]]")

        expect(disclosure).to be_present
        expect(disclosure["open"]).to be_nil
      end

      it "places runner/model/token-usage/archive controls inside the desktop session-details disclosure" do
        # @spec CHAT-API-009
        # #3925: the right column of the old desktop header (runner/model
        # selectors, token usage tile, archive/unarchive buttons) and the
        # project/updated metadata under the title now live inside the
        # Session details disclosure. They are not part of the always-visible
        # chrome and must not appear at the top of the desktop header.
        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)

        doc = Nokogiri::HTML(response.body)
        header = desktop_header_in(doc)
        disclosure = header.at_xpath(".//details[summary[contains(., 'Session details')]]")
        summary = disclosure&.at_xpath("./summary")

        expect(disclosure).to be_present
        expect(summary).to be_present

        runner_select = disclosure.at_xpath(".//select[@name='chat_session[runner_id]']")
        model_select = disclosure.at_xpath(".//select[@name='chat_session[model]']")
        token_usage = disclosure.at_xpath(".//span[@data-chat-target='tokenUsage']")

        expect(runner_select).to be_present
        expect(model_select).to be_present
        expect(token_usage).to be_present

        # The runner/model/token usage elements must live in the disclosure
        # body, not the always-visible summary line.
        expect(summary.at_xpath(".//select[@name='chat_session[runner_id]']")).to be_nil
        expect(summary.at_xpath(".//select[@name='chat_session[model]']")).to be_nil
        expect(summary.at_xpath(".//span[@data-chat-target='tokenUsage']")).to be_nil
      end

      it "does not render the redundant Active/Inline status badges in the desktop chat header" do
        # @spec CHAT-API-009
        # #3925: chat_session_status_badge (Active/Idle/Closed/Archived)
        # duplicates the per-row state on the chat list and the Active vs
        # Archived tabs on the chat page. chat_mode_badge (Inline/Container)
        # is opaque to most users. Both helpers are removed from the chat
        # panel header; they remain on the popup and the sidebar card.
        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)

        doc = Nokogiri::HTML(response.body)
        header = desktop_header_in(doc)
        disclosure = header.at_xpath(".//details[summary[contains(., 'Session details')]]")
        summary = disclosure&.at_xpath("./summary")

        # CHAT_SESSION_STATUS_STYLES["active"] -> bg-green-100 text-green-700,
        # but CHAT_CONTAINER_CAPABILITY_STYLES["ready"] reuses the same classes
        # for the workspace capability badge, which lives inside the Session
        # details disclosure body (still inside this <header>). Scope the lookup
        # to spans outside the always-visible chrome (the disclosure summary)
        # and exclude spans that are the workspace capability badge, identified
        # by its `data-chat-target="capabilityBadge"` stimulus target.
        chrome_spans = summary ? summary.css("span") : []
        off_chrome = header.css("span").to_a - chrome_spans
        non_capability = off_chrome.reject { |span| span["data-chat-target"] == "capabilityBadge" }
        expect(non_capability.select { |span| (span["class"] || "").split.include?("bg-green-100") && (span["class"] || "").split.include?("text-green-700") }).to be_empty

        # CHAT_MODE_STYLES["inline"] -> bg-blue-100 text-blue-700. The capability
        # palette does not use blue, so the simple CSS check stays safe.
        expect(header.css("span.bg-blue-100.text-blue-700")).to be_empty
      end

      it "does not render the redundant Active/Inline status badges when the workspace capability is ready" do
        # @spec CHAT-API-009
        # #3925 regression: CHAT_CONTAINER_CAPABILITY_STYLES["ready"] reuses
        # the same green classes as CHAT_SESSION_STATUS_STYLES["active"], so
        # a naive CSS lookup against the desktop header would match the
        # workspace capability badge (which lives inside the Session details
        # disclosure body, still inside <header>) and report a false-positive
        # "Active badge reappeared" failure. Drive a workspace chat so the
        # green capability badge is actually rendered, then confirm the
        # redundant status/mode badges are still absent and that the
        # capability badge is the only green span in the header.
        chat_session = create(:chat_session, :workspace, account: account, created_by: user)

        get chat_session_path(chat_session)
        expect(response).to have_http_status(:ok)

        doc = Nokogiri::HTML(response.body)
        header = desktop_header_in(doc)
        disclosure = header.at_xpath(".//details[summary[contains(., 'Session details')]]")
        summary = disclosure&.at_xpath("./summary")

        # Sanity: the workspace capability badge really is present in green,
        # otherwise this regression test would not be exercising the
        # collision between the two badge palettes.
        capability_badge = header.at_xpath(".//span[@data-chat-target='capabilityBadge']")
        expect(capability_badge).to be_present
        expect(capability_badge["class"].to_s.split).to include("bg-green-100", "text-green-700")

        # Apply the same scoping the primary test uses: only spans outside
        # the always-visible chrome and not the capability badge may carry
        # the green status classes. If a future change reintroduces the
        # status badge, the assertion below will fail; if the green-CSS
        # check ever drifts back to a header-wide lookup, this test will
        # fail with the original false-positive message.
        chrome_spans = summary ? summary.css("span") : []
        off_chrome = header.css("span").to_a - chrome_spans
        non_capability = off_chrome.reject { |span| span["data-chat-target"] == "capabilityBadge" }
        expect(non_capability.select { |span| (span["class"] || "").split.include?("bg-green-100") && (span["class"] || "").split.include?("text-green-700") }).to be_empty

        # The green workspace capability badge is the *only* green span in
        # the header — i.e., it never competes with another badge for the
        # same classes from a different palette.
        green_spans = header.css("span.bg-green-100.text-green-700").to_a
        expect(green_spans.map { |span| span["data-chat-target"] }).to eq([ "capabilityBadge" ])

        # CHAT_MODE_STYLES does not collide with the capability palette, so
        # the CSS check stays safe.
        expect(header.css("span.bg-blue-100.text-blue-700")).to be_empty
      end

      it "keeps the measured viewport height bound when the show page renders a flash banner" do
        # @spec CHAT-API-008
        patch chat_session_path(chat_session), params: {
          chat_session: { title: "Retitled session" }
        }

        expect(response).to redirect_to(chat_session_path(chat_session))

        follow_redirect!

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Chat session updated.")

        doc = Nokogiri::HTML(response.body)
        panel = doc.at_xpath("//div[@data-controller='chat']")

        expect(panel).to be_present
        # Anchored so a `max-height:` declaration cannot satisfy it by
        # substring. The bound uses `--chat-panel-bottom-space` so the
        # subtraction tracks the page's actual bottom padding per breakpoint
        # (1rem below `lg`, 2rem at `lg`+); see the CHAT-API-009 mobile test
        # below for the responsive variant.
        expect(panel["style"]).to match(
          /(?:\A|;\s*)height: calc\(100dvh - var\(--chat-panel-offset-top, 0px\) - var\(--chat-panel-bottom-space, 2rem\)\)/
        )
      end

      it "renders the auto-approve checkbox reflecting the session state" do
        chat_session.update!(auto_approve: true)

        get chat_session_path(chat_session)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(name="chat_session[auto_approve]"))
        expect(response.body).to include("Auto-approve actions")
        expect(response.body).to include(%(checked="checked"))
      end

      it "defaults the new-session modal auto-approve checkbox from user settings" do
        user.settings.update!(default_auto_approve: true)

        get chat_session_path(chat_session)

        expect(response).to have_http_status(:ok)
        doc = Nokogiri::HTML(response.body)
        modal_checkbox = doc.at_css(
          "dialog[data-chat-session-list-target='modal'] input[name='chat_session[auto_approve]'][type='checkbox']"
        )

        expect(modal_checkbox).to be_present
        expect(modal_checkbox["checked"]).to eq("checked")
      end

      it "leaves the new-session modal auto-approve checkbox unchecked when the user disables the default" do
        user.settings.update!(default_auto_approve: false)

        get chat_session_path(chat_session)

        expect(response).to have_http_status(:ok)
        doc = Nokogiri::HTML(response.body)
        modal_checkbox = doc.at_css(
          "dialog[data-chat-session-list-target='modal'] input[name='chat_session[auto_approve]'][type='checkbox']"
        )

        expect(modal_checkbox).to be_present
        expect(modal_checkbox["checked"]).to be_nil
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
        expect(response.body).to include("Untitled chat")
        expect(response.body).to include("Archive &amp; New Chat")
        expect(response.body).to include("New Chat")
        expect(response.body).to include("Open page")
        expect(response.body).to include("Projects - Paid")
      end

      it "wraps the popup capability panel inside the chat controller scope" do
        get chat_session_path(chat_session), params: { display: "popup" }, headers: { "Accept" => "text/html" }

        expect(response).to have_http_status(:ok)

        doc = Nokogiri::HTML(response.body)
        chat_root = doc.at_css("section[data-controller='chat'][data-chat-session-id-value]")
        capability_panel = doc.at_css("[data-chat-target='capabilityPanel']")

        expect(chat_root).to be_present
        expect(capability_panel).to be_present
        expect(chat_root.at_css("[data-chat-target='capabilityPanel']")).to eq(capability_panel)
      end

      it "only offers API-key-backed runners in the inline chat runner selector" do
        # @spec CHAT-API-006
        create(:runner, user: user, runner_key: "codex", auth_type: "subscription", enabled_for_chat: true)
        api_runner = create(:runner, :api_key, user: user, runner_key: "opencode", name: "API Chat Runner",
          provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })

        get chat_session_path(chat_session)

        doc = Nokogiri::HTML(response.body)
        runner_options = doc.css("select[name='chat_session[runner_id]'] option").map(&:text)
        expect(runner_options).to include(api_runner.display_name)
        expect(runner_options).not_to include("OpenAI Codex CLI")
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
        expect(response.body).not_to include(%(name="chat_session[auto_approve]"))
        expect(response.body).not_to include(%(name="content"))
        expect(response.body).not_to include("New Chat")
      end

      it "does not render popup new-chat controls" do
        get chat_session_path(chat_session), params: { display: "popup" }, headers: { "Accept" => "text/html" }

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Archive &amp; New Chat")
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

    it "renders the stable sidebar frame for non-archived sessions" do
      create(:chat_session, account: account, created_by: user, title: "Active")

      get sidebar_page_chat_sessions_path,
        params: { archived: "false" },
        headers: { "Turbo-Frame" => "chat_sessions_list" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/<turbo-frame[^>]*id="chat_sessions_list"/)
      expect(response.body).to match(/<div[^>]*id="chat_sessions_list_active"/)
      expect(response.body).to include("Active")
    end

    it "renders the stable sidebar frame for archived sessions" do
      create(:chat_session, :archived, account: account, created_by: user, title: "Archived")

      get sidebar_page_chat_sessions_path,
        params: { archived: "true" },
        headers: { "Turbo-Frame" => "chat_sessions_list" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/<turbo-frame[^>]*id="chat_sessions_list"/)
      expect(response.body).to match(/<div[^>]*id="chat_sessions_list_archived"/)
      expect(response.body).to include("Archived")
    end

    it "targets the stable sidebar frame from both filter tabs" do
      get sidebar_page_chat_sessions_path,
        params: { archived: "false" },
        headers: { "Turbo-Frame" => "chat_sessions_list" }

      expect(response.body.scan('data-turbo-frame="chat_sessions_list"').size).to eq(2)
    end

    it "keeps lazy loading available after switching filters" do
      51.times do |index|
        create(:chat_session, :archived, account: account, created_by: user, title: "Archived #{index}", updated_at: index.minutes.ago)
      end

      get sidebar_page_chat_sessions_path,
        params: { archived: "true" },
        headers: { "Turbo-Frame" => "chat_sessions_list" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('loading="lazy"')
      expect(response.body).to match(/<turbo-frame[^>]*id="sidebar_page_/)
      expect(response.body).to include("/chat/sidebar_page?archived=true&amp;before_id=")
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

      it "updates the auto-approve flag and echoes it in the response" do
        patch chat_session_path(chat_session, format: :json), params: { auto_approve: "true" }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["auto_approve"]).to be(true)
        expect(chat_session.reload).to be_auto_approve
      end

      # @spec CHAT-SESSION-PREFERENCES-001
      it "updates the auto-approve flag in place for Turbo Stream requests" do
        patch chat_session_path(chat_session),
          params: { chat_session: { auto_approve: "true" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:no_content)
        expect(response.headers["Location"]).to be_blank
        expect(response.body).to be_blank
        expect(chat_session.reload).to be_auto_approve
      end

      it "updates values submitted under chat_session params" do
        patch chat_session_path(chat_session), params: { chat_session: { title: "Updated From Form", model: "gpt-4.1" } }

        expect(response).to redirect_to(chat_session_path(chat_session))
        expect(chat_session.reload.title).to eq("Updated From Form")
        expect(chat_session.model).to eq("gpt-4.1")
      end

      it "saves the selected chat runner and model together in place" do
        # @spec CHAT-SESSION-PREFERENCES-002
        runner = create(:runner, :api_key, user: user, runner_key: "opencode",
          provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })

        patch chat_session_path(chat_session),
          params: { chat_session: { runner_id: runner.id, model: "moonshotai/kimi-k2" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:no_content)
        expect(chat_session.reload).to have_attributes(runner_id: runner.id, model: "moonshotai/kimi-k2")
      end

      it "rejects runner updates that cannot build an API chat client" do
        runner = create(:runner, user: user, runner_key: "codex", auth_type: "subscription", enabled_for_chat: true)

        patch chat_session_path(chat_session, format: :json), params: { runner_id: runner.id }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to include("API-key chat runner")
        expect(chat_session.reload.runner_id).not_to eq(runner.id)
      end

      it "accepts an API-key chat runner owned by another user in the same account" do
        teammate = create(:user, account: account)
        runner = create(:runner, :api_key, user: teammate, runner_key: "opencode",
          provider_api_key: create(:provider_api_key, user: teammate, api_service_type: "openrouter"),
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })

        patch chat_session_path(chat_session, format: :json), params: { runner_id: runner.id }

        expect(response).to have_http_status(:ok)
        expect(chat_session.reload.runner_id).to eq(runner.id)
      end

      it "rejects runners from a different account" do
        other_account = create(:account)
        other_user = create(:user, account: other_account)
        runner = create(:runner, :api_key, user: other_user, runner_key: "opencode",
          provider_api_key: create(:provider_api_key, user: other_user, api_service_type: "openrouter"),
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })

        patch chat_session_path(chat_session, format: :json), params: { runner_id: runner.id }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to include("must belong to the same account")
        expect(chat_session.reload.runner_id).not_to eq(runner.id)
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

  describe "PATCH /chat/:id/archive" do
    let!(:chat_session) { create(:chat_session, account: account, created_by: user, title: "Current chat") }

    context "when authenticated" do
      before { sign_in user }

      it "archives the session and returns json" do
        create(:chat_message, chat_session: chat_session, role: "user", content: "Hello")

        patch archive_chat_session_path(chat_session, format: :json)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["status"]).to eq("archived")
        expect(chat_session.reload.status).to eq("archived")
        expect(chat_session.metadata["archived_at"]).to be_present
      end

      it "redirects to another visible session for html requests" do
        next_session = create(:chat_session, account: account, created_by: user, title: "Next chat")

        patch archive_chat_session_path(chat_session)

        expect(response).to redirect_to(chat_session_path(next_session))
        expect(flash[:notice]).to eq("Chat session archived.")
        expect(chat_session.reload.status).to eq("archived")
      end

      it "redirects back to /chat when no other visible session exists" do
        patch archive_chat_session_path(chat_session)

        expect(response).to redirect_to(chat_sessions_path)
        expect(chat_session.reload.status).to eq("archived")
      end

      it "rejects re-archiving an already archived session" do
        chat_session.update!(status: "archived")

        patch archive_chat_session_path(chat_session, format: :json)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to eq("Chat session is archived.")
        expect(chat_session.reload.status).to eq("archived")
      end

      it "rejects archiving an archived session via html" do
        chat_session.update!(status: "archived")

        patch archive_chat_session_path(chat_session)

        expect(response).to redirect_to(chat_session_path(chat_session))
        expect(flash[:alert]).to eq("Chat session is archived.")
        expect(chat_session.reload.status).to eq("archived")
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

      it "rejects closing an archived session" do
        chat_session.update!(status: "archived")

        delete chat_session_path(chat_session, format: :json)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to eq("Chat session is archived.")
        expect(chat_session.reload.status).to eq("archived")
      end
    end
  end

  describe "archived read-only contract" do
    let!(:chat_session) { create(:chat_session, :archived, account: account, created_by: user) }

    before { sign_in user }

    it "still allows GET /chat/:id for an archived session" do
      get chat_session_path(chat_session, format: :json)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("archived")
    end

    it "still allows PATCH /chat/:id/unarchive" do
      freeze_time do
        patch unarchive_chat_session_path(chat_session, format: :json)
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("active")
      expect(chat_session.reload.status).to eq("active")
      expect(chat_session.idle_timeout_at).to be_within(5.seconds).of(30.minutes.from_now)
      expect(chat_session.metadata["unarchived_at"]).to be_present
    end

    it "rejects PATCH /chat/:id on an archived session via json" do
      patch chat_session_path(chat_session, format: :json), params: { title: "Renamed after archive" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Chat session is archived.")
      expect(chat_session.reload.title).not_to eq("Renamed after archive")
    end

    it "rejects DELETE /chat/:id on an archived session via json" do
      delete chat_session_path(chat_session, format: :json)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Chat session is archived.")
      expect(chat_session.reload.status).to eq("archived")
    end

    it "rejects PATCH /chat/:id/archive on an archived session via json" do
      patch archive_chat_session_path(chat_session, format: :json)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Chat session is archived.")
      expect(chat_session.reload.status).to eq("archived")
    end

    it "rejects POST /chat/:id/clone_project on an archived session via json" do
      project = create(:project, account: account)

      expect {
        post clone_project_chat_session_path(chat_session, format: :json), params: { project_id: project.id }
      }.not_to change(ChatMessage, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Chat session is archived.")
      expect(chat_session.reload.clone_manifest).to be_empty
    end

    it "rejects POST /chat/:id/clone_project on an archived session via html" do
      project = create(:project, account: account)

      expect {
        post clone_project_chat_session_path(chat_session), params: { project_id: project.id }
      }.not_to change(ChatMessage, :count)

      expect(response).to redirect_to(chat_session_path(chat_session))
      expect(flash[:alert]).to eq("Chat session is archived.")
      expect(chat_session.reload.clone_manifest).to be_empty
    end

    it "redirects html mutating requests back to the archived session show page" do
      patch chat_session_path(chat_session), params: { title: "Renamed after archive" }

      expect(response).to redirect_to(chat_session_path(chat_session))
      expect(flash[:alert]).to eq("Chat session is archived.")
    end
  end

  describe "capability panel reopen control" do
    let(:account) { create(:account) }
    let(:user) { create(:user, :owner, account: account) }
    let(:chat_session) { create(:chat_session, account: account, created_by: user) }

    before { sign_in user }

    it "renders the reopen form visible with the toggle attribute on the form when stopped" do
      chat_session.update!(container_capability: "stopped")

      get chat_session_path(chat_session)

      form = Nokogiri::HTML(response.body).at_css("form[action='#{reopen_chat_session_path(chat_session)}']")

      expect(form).to be_present
      expect(form["class"]).not_to include('hidden')
      # The Stimulus toggle target must live on the same element that carries
      # the initial hidden state, so a live transition to stopped reveals the CTA.
      expect(form["data-chat-capability-stopped-only"]).to be_present
    end

    it "hides the reopen form but keeps the toggle attribute on the same element when not stopped" do
      chat_session.update!(container_capability: "ready")

      get chat_session_path(chat_session)

      form = Nokogiri::HTML(response.body).at_css("form[action='#{reopen_chat_session_path(chat_session)}']")

      expect(form).to be_present
      expect(form["class"]).to include('hidden')
      expect(form["data-chat-capability-stopped-only"]).to be_present
    end
  end

  def desktop_header_in(doc)
    doc.xpath("//div[@data-controller='chat']/header").last
  end

  def desktop_workspace_disclosure_in(body)
    doc = Nokogiri::HTML(body)
    desktop_header = desktop_header_in(doc)
    desktop_header
      &.at_xpath(".//div[@data-chat-target='capabilityPanel']")
      &.ancestors("details")
      &.first
  end

  def create_api_chat_runner
    create(:runner, :api_key, user: user, runner_key: "opencode",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })
  end
end
