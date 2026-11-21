# frozen_string_literal: true

require "rails_helper"

# @spec CHAT-API-024 CHAT-API-027
RSpec.describe "Bounded chat tool history" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let!(:chat_session) { create(:chat_session, account:, created_by: user) }

  before { sign_in user }

  def insert_tools(count, session: chat_session)
    now = 1.minute.ago
    rows = count.times.map do |index|
      { chat_session_id: session.id, role: "tool", tool_name: "search", tool_result: { "stdout" => "x" * 1024 },
        metadata: {}, external_id: SecureRandom.uuid, created_at: now + index / 1000.0, updated_at: now }
    end
    ChatMessage.insert_all!(rows, returning: %w[id]).rows.flatten
  end

  def document = Nokogiri::HTML(response.body)
  def history_path(session = chat_session) = "/chat/#{session.id}/tool_history"

  it "bounds the first response and moves outer history before the complete tool run" do
    intro = create(:chat_message, chat_session:, content: "Before the tool run", created_at: 2.minutes.ago)
    ids = insert_tools(120)

    get chat_session_path(chat_session), headers: { "Accept" => "text/html" }

    expect(response).to have_http_status(:ok)
    expect(document.css("[data-chat-tool-card]").size).to eq(50)
    expect(document.css("[data-chat-tool-group]").size).to eq(1)
    expect(document.at_css("[data-chat-tool-group-summary]").text).to include("50 tool actions shown")
    expect(document.at_css("[data-chat-tool-history-more]")["href"]).to include("anchor_id=#{ids.last}", "before=#{ids[-50]}")
    older_sources = document.css("turbo-frame[src]").map { |frame| frame["src"] }
    expect(older_sources).to include(include("/older_messages", "before=#{ids.first}"))
    expect(intro.id).to be < ids.first
  end

  it "retains the same bounded history controls in popup and Inbox frame rendering" do
    create(:chat_message, chat_session:, content: "Before tools", created_at: 2.minutes.ago)
    ids = insert_tools(120)

    [ { display: "popup" }, { frame: "inbox-detail" } ].each do |params|
      get chat_session_path(chat_session), params:, headers: { "Accept" => "text/html" }

      expect(response).to have_http_status(:ok)
      expect(document.css("[data-chat-tool-card]").size).to eq(50)
      expect(document.at_css("[data-chat-tool-history-more]")["href"]).to include("before=#{ids[-50]}")
      expect(document.at_css("turbo-frame[src*='older_messages']")["src"]).to include("before=#{ids.first}")
    end
  end

  it "makes every omitted tool reachable in bounded ordered JSON pages" do
    ids = insert_tools(120)

    get "#{history_path}.json", params: { anchor_id: ids.last, before: ids[-50] }

    expect(response).to have_http_status(:ok)
    first = response.parsed_body
    expect(first.fetch("messages").map { |message| message.fetch("id") }).to eq(ids[20, 50])
    expect(first.fetch("has_more")).to be(true)
    get "#{history_path}.json", params: { anchor_id: ids.last, before: first.fetch("next_before") }
    expect(response).to have_http_status(:ok)
    last = response.parsed_body
    expect(last.fetch("messages").map { |message| message.fetch("id") }).to eq(ids.first(20))
    expect(last.fetch("has_more")).to be(false)
    expect(last["next_before"]).to be_nil
  end

  it "retains the history disclosure when only one tool fits in the outer page" do
    insert_tools(80)
    49.times { |index| create(:chat_message, :assistant, chat_session:, content: "Later #{index}") }

    get chat_session_path(chat_session), headers: { "Accept" => "text/html" }

    expect(response).to have_http_status(:ok)
    expect(document.css("[data-chat-tool-card]").size).to eq(1)
    expect(document.css("[data-chat-tool-group]").size).to eq(1)
    expect(document.at_css("[data-chat-tool-history-more]")).to be_present
  end

  it "stops inner history at a pending confirmation instead of crossing into an older run" do
    old_ids = insert_tools(10)
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending", created_at: 30.seconds.ago)
    ids = insert_tools(60)
    ChatMessage.where(id: ids).update_all(created_at: 10.seconds.ago)

    get "#{history_path}.json", params: { anchor_id: ids.last, before: ids[-50] }

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body
    expect(payload.fetch("messages").map { |message| message.fetch("id") }).to eq(ids.first(10))
    expect(payload.fetch("has_more")).to be(false)
    expect(payload.fetch("messages").map { |message| message.fetch("id") } & old_ids).to be_empty
  end

  it "keeps a stable history window when live tools are appended and ignores requested larger limits" do
    ids = insert_tools(120)
    live_ids = insert_tools(5)

    get "#{history_path}.json", params: { anchor_id: ids.last, before: ids[-50], limit: 10_000 }

    expect(response).to have_http_status(:ok)
    messages = response.parsed_body.fetch("messages").map { |message| message.fetch("id") }
    expect(messages).to eq(ids[20, 50])
    expect(messages & live_ids).to be_empty
  end

  it "does not group history across an error notice" do
    insert_tools(10)
    create(:chat_message, :tool, chat_session:, content: "Provider unavailable",
      metadata: { "provider_error_notice" => true })
    ids = insert_tools(60)

    get "#{history_path}.json", params: { anchor_id: ids.last, before: ids[-50] }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("messages").map { |message| message.fetch("id") }).to eq(ids.first(10))
    expect(response.parsed_body.fetch("has_more")).to be(false)
  end

  it "rejects malformed cursors and anchors outside the authorized session" do
    ids = insert_tools(60)
    get "#{history_path}.json", params: { anchor_id: ids.last, before: "invalid" }
    expect(response).to have_http_status(:bad_request)

    other = create(:chat_session, account:, created_by: user)
    get "#{history_path(other)}.json", params: { anchor_id: ids.last, before: ids.first }
    expect(response).to have_http_status(:not_found)
  end

  it "does not expose another tenant's tool history" do
    foreign = create(:chat_session)
    ids = insert_tools(60, session: foreign)

    get "#{history_path(foreign)}.json", params: { anchor_id: ids.last, before: ids.first }

    expect(response).to have_http_status(:not_found)
  end
end
