# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ResolveToolCallJob, type: :job do
  # @spec CHAT-API-004
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:stream_message_id) { SecureRandom.uuid }
  let(:stream_name) { "chat_session:#{chat_session.id}" }
  let(:tool_call_message) do
    create(:chat_message, chat_session: chat_session,
      role: "assistant", content: nil,
      tool_name: "trigger_agent_run", tool_call_id: "call_1",
      tool_arguments: { "project_id" => 1 }, tool_status: "pending")
  end

  it "resolves the tool call and broadcasts message_complete" do
    assistant_msg = create(:chat_message, :assistant, chat_session: chat_session,
      tokens_input: 5, tokens_output: 3)
    allow(ChatSessions::ResolveToolCall).to receive(:call).and_return(assistant_msg)

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        message_id: tool_call_message.id,
        decision: "approve",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_complete", tokens: { input: 5, output: 3 }))
  end

  it "pauses the session and persists a durable pause notice when every runner is rate limited" do
    # @spec CHAT-API-017
    error = AgentHarness::RateLimitError.new("API rate limit exceeded", reset_time: 10.minutes.from_now)
    allow(ChatSessions::ResolveToolCall).to receive(:call).and_raise(error)

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        message_id: tool_call_message.id,
        decision: "approve",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_created", role: "system"))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "error"))

    expect(chat_session.reload).to be_rate_limited
    expect(chat_session.messages.where(role: "system").last).to be_rate_limit_paused
  end

  it "broadcasts error and discards on missing session" do
    expect {
      described_class.perform_now(
        chat_session_id: -1,
        message_id: 1,
        decision: "approve",
        stream_message_id: stream_message_id
      )
    }.not_to raise_error
  end
end
