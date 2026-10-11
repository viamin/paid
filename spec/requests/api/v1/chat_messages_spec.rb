# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mobile chat messages API" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:plaintext) { PersonalAccessToken.generate_plaintext }
  let(:headers) do
    create(:personal_access_token, user:, account:, name: "iPhone", plaintext:)
    { "Authorization" => "Bearer #{plaintext}" }
  end

  # @spec MOBILE-API-012
  it "returns oldest-first cursor pages with a next_before cursor" do
    messages = create_list(:chat_message, 3, chat_session:)

    get "/api/v1/chat/sessions/#{chat_session.id}/messages", params: { limit: 2 }, headers: headers

    expect(response).to have_http_status(:ok)
    page = response.parsed_body
    expect(page.fetch("messages").map { |message| message.fetch("id") }).to eq(messages.last(2).map(&:id))
    expect(page.fetch("next_before")).to eq(messages.second.id)

    get "/api/v1/chat/sessions/#{chat_session.id}/messages", params: { before: page.fetch("next_before"), limit: 2 }, headers: headers
    expect(response.parsed_body.fetch("messages").map { |message| message.fetch("id") }).to eq([ messages.first.id ])
    expect(response.parsed_body).not_to have_key("next_before")
  end

  # @spec MOBILE-API-013 CHAT-API-002 MOBILE-API-015
  it "sends JSON or SSE with the existing event catalog and unified JSON errors" do
    assistant = create(:chat_message, :assistant, chat_session:, content: "Done")
    allow(ChatSessions::SendMessage).to receive(:call).and_return(assistant)

    post "/api/v1/chat/sessions/#{chat_session.id}/messages", params: { content: "Hello" }, headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("role" => "assistant")

    allow(ChatSessions::SendMessage).to receive(:call) { |**args| args[:on_chunk].call("Done"); assistant }
    post "/api/v1/chat/sessions/#{chat_session.id}/messages", params: { content: "Hello" }, headers: headers.merge("Accept" => "text/event-stream")
    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Accel-Buffering"]).to eq("no")
    expect(response.body).to include("event: message_start", "event: message_chunk", "event: message_complete")

    post "/api/v1/chat/sessions/#{chat_session.id}/messages", params: { content: "" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
  end

  # @spec MOBILE-API-013 CHAT-API-002
  it "includes the session model in message_start, matching the web SSE contract" do
    chat_session.update!(model: "claude-opus-5-5")
    assistant = create(:chat_message, :assistant, chat_session:, content: "Done")
    allow(ChatSessions::SendMessage).to receive(:call).and_return(assistant)

    post "/api/v1/chat/sessions/#{chat_session.id}/messages", params: { content: "Hello" },
      headers: headers.merge("Accept" => "text/event-stream")

    expect(response.body).to match(/event: message_start\ndata: .*"model":"claude-opus-5-5"/)
  end

  # @spec MOBILE-API-013 CHAT-API-002
  it "emits message_created for a persisted fallback notice" do
    notice = create(:chat_message, :assistant, chat_session:, content: "Falling back", metadata: { "fallback_notice" => true })
    allow(ChatSessions::SendMessage).to receive(:call) { |**args| args[:on_message_persisted].call(notice); notice }

    post "/api/v1/chat/sessions/#{chat_session.id}/messages", params: { content: "Hello" },
      headers: headers.merge("Accept" => "text/event-stream")

    expect(response.body).to include("event: message_created")
    expect(response.body).to include('"fallback_notice":true')
  end

  # @spec MOBILE-API-013 CHAT-API-002
  it "emits message_created for a persisted token-limit notice" do
    notice = create(:chat_message, :assistant, chat_session:, content: "Token limit reached", metadata: { "token_limit_error" => true })
    allow(ChatSessions::SendMessage).to receive(:call) { |**args| args[:on_message_persisted].call(notice); notice }

    post "/api/v1/chat/sessions/#{chat_session.id}/messages", params: { content: "Hello" },
      headers: headers.merge("Accept" => "text/event-stream")

    expect(response.body).to include("event: message_created")
    expect(response.body).to include('"token_limit_error":true')
  end

  # @spec MOBILE-API-013 CHAT-API-014
  it "preserves the token-limit error payload after an SSE stream starts" do
    error = ChatSessions::TokenLimitExceededError.new("Session token limit reached", remaining: 0, limit: 100, limit_type: "session", used: 110)
    allow(ChatSessions::SendMessage).to receive(:call).and_raise(error)

    post "/api/v1/chat/sessions/#{chat_session.id}/messages", params: { content: "Hello" },
      headers: headers.merge("Accept" => "text/event-stream")

    expect(response.body).to include("event: error\ndata: {\"error\":\"Session token limit reached\",\"limit_type\":\"session\",\"limit\":100,\"used\":110}")
  end

  # @spec MOBILE-API-014 CHAT-API-004
  it "resolves tool calls through JSON and SSE" do
    tool_call = create(:chat_message, :tool_call, chat_session:, tool_status: "pending")
    assistant = create(:chat_message, :assistant, chat_session:, content: "Approved")
    allow(ChatSessions::ResolveToolCall).to receive(:call).and_return(assistant)

    post "/api/v1/chat/sessions/#{chat_session.id}/messages/#{tool_call.id}/resolve", params: { decision: "approve" }, headers: headers
    expect(response).to have_http_status(:ok)

    allow(ChatSessions::ResolveToolCall).to receive(:call) { |**args| args[:on_tool_call_resolved].call(tool_call); assistant }
    post "/api/v1/chat/sessions/#{chat_session.id}/messages/#{tool_call.id}/resolve", params: { decision: "deny" }, headers: headers.merge("Accept" => "text/event-stream")
    expect(response.body).to include("event: message_start", "event: message_tool_resolved", "event: message_complete")
    expect(response.body).to match(/event: message_start\ndata: \{"message_id":"[^"]+"\}\n\n/)
  end

  # @spec MOBILE-API-014 CHAT-API-004 MOBILE-API-015
  it "returns a conflict when another client already resolved the tool call" do
    tool_call = create(:chat_message, :tool_call, chat_session:, tool_status: "pending")
    allow(ChatSessions::ResolveToolCall).to receive(:call)
      .and_raise(ChatSessions::ResolveToolCall::ResolutionConflictError, "Tool call is not awaiting confirmation")

    post "/api/v1/chat/sessions/#{chat_session.id}/messages/#{tool_call.id}/resolve", params: { decision: "approve" }, headers: headers

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq(
      "error" => { "code" => "conflict", "message" => "Tool call is not awaiting confirmation", "details" => {} }
    )
  end

  # @spec MOBILE-API-013 MOBILE-API-015 CHAT-API-002
  it "enforces the per-user and per-session send limit after bearer token limiting" do
    stub_const("ChatMessages::RateLimit::MAX_REQUESTS", 0)
    ChatMessages::RateLimit::FALLBACK_CACHE.clear

    post "/api/v1/chat/sessions/#{chat_session.id}/messages", params: { content: "Hello" }, headers: headers

    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"]).to be_present
    expect(response.parsed_body.dig("error", "code")).to eq("rate_limited")
  end
end
