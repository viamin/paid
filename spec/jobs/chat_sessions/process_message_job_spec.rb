# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ProcessMessageJob, type: :job do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:stream_message_id) { SecureRandom.uuid }
  let(:stream_name) { "chat_session:#{chat_session.id}" }

  let(:llm_client) { instance_double(ChatSessions::BuildLlmClient::HttpClient) }

  before do
    allow(ChatSessions::BuildLlmClient).to receive(:call).and_return(llm_client)
  end

  it "broadcasts message_start before invoking SendMessage" do
    assistant_msg = create(:chat_message, :assistant, chat_session: chat_session,
      tokens_input: 20, tokens_output: 10)

    allow(ChatSessions::SendMessage).to receive(:call).and_return(assistant_msg)

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Hello",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_start", message_id: stream_message_id))
  end

  it "calls SendMessage and broadcasts message_complete with aggregate tokens" do
    assistant_msg = create(:chat_message, :assistant, chat_session: chat_session,
      tokens_input: 20, tokens_output: 10)

    allow(ChatSessions::SendMessage).to receive(:call).and_return(assistant_msg)

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Hello",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(
        type: "message_complete",
        message_id: stream_message_id,
        tokens: { input: 20, output: 10 }
      ))
  end

  it "broadcasts message_complete with nil tokens when a write tool pauses" do
    pending_msg = create(:chat_message, chat_session: chat_session,
      role: "assistant", content: nil,
      tool_name: "trigger_agent_run", tool_call_id: "call_pause",
      tool_arguments: { "project_id" => 1 }, tool_status: "pending")

    allow(ChatSessions::SendMessage).to receive(:call) do |**kwargs|
      kwargs[:on_message_persisted]&.call(pending_msg)
      nil
    end

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Run it",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_tool_confirmation", tool_name: "trigger_agent_run"))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_complete", message_id: stream_message_id,
        tokens: { input: nil, output: nil }))
  end

  it "does not broadcast an error when a write tool pauses" do
    pending_msg = create(:chat_message, chat_session: chat_session,
      role: "assistant", content: nil,
      tool_name: "trigger_agent_run", tool_call_id: "call_pause",
      tool_arguments: { "project_id" => 1 }, tool_status: "pending")

    allow(ChatSessions::SendMessage).to receive(:call) do |**kwargs|
      kwargs[:on_message_persisted]&.call(pending_msg)
      nil
    end

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Run it",
        stream_message_id: stream_message_id
      )
    }.not_to have_broadcasted_to(stream_name).with(hash_including(type: "error"))
  end

  it "broadcasts message_tool_call for assistant messages with a tool name and nil content" do
    tool_call_msg = create(:chat_message, chat_session: chat_session,
      role: "assistant", content: nil,
      tool_name: "list_projects", tool_call_id: "call_123", tool_arguments: { "query" => "all" })
    assistant_msg = create(:chat_message, :assistant, chat_session: chat_session, tokens_input: 5, tokens_output: 3)
    allow(ChatSessions::SendMessage).to receive(:call) do |**kwargs|
      kwargs[:on_message_persisted]&.call(tool_call_msg)
      assistant_msg
    end

    expect {
      described_class.perform_now(chat_session_id: chat_session.id, content: "Use a tool",
        stream_message_id: stream_message_id)
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_tool_call", tool_name: "list_projects",
        tool_call_id: "call_123", tool_arguments: { "query" => "all" }))
  end

  it "broadcasts message_tool_result for tool-role messages" do
    tool_result_msg = create(:chat_message, chat_session: chat_session,
      role: "tool", content: '{"projects":[]}',
      tool_name: "list_projects", tool_call_id: "call_123", tool_result: { "projects" => [] })
    assistant_msg = create(:chat_message, :assistant, chat_session: chat_session, tokens_input: 5, tokens_output: 3)
    allow(ChatSessions::SendMessage).to receive(:call) do |**kwargs|
      kwargs[:on_message_persisted]&.call(tool_result_msg)
      assistant_msg
    end

    expect {
      described_class.perform_now(chat_session_id: chat_session.id, content: "Use a tool",
        stream_message_id: stream_message_id)
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_tool_result", tool_name: "list_projects",
        tool_call_id: "call_123", tool_result: { "projects" => [] }))
  end

  it "broadcasts message_created for regular user and assistant messages" do
    user_msg = create(:chat_message, chat_session: chat_session, role: "user", content: "Hello")
    assistant_msg = create(:chat_message, :assistant, chat_session: chat_session,
      tokens_input: 10, tokens_output: 5)

    allow(ChatSessions::SendMessage).to receive(:call) do |**kwargs|
      kwargs[:on_message_persisted]&.call(user_msg)
      kwargs[:on_message_persisted]&.call(assistant_msg, stream_message_id: stream_message_id)
      assistant_msg
    end

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Hello",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_created", role: "user"))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_created", role: "assistant"))
  end

  it "broadcasts message_complete even when a tool call fails" do
    tool_result_msg = create(:chat_message, chat_session: chat_session,
      role: "tool", content: '{"status":"error"}',
      tool_name: "list_projects", tool_call_id: "call_err",
      tool_result: { "status" => "error" })

    assistant_msg = create(:chat_message, :assistant, chat_session: chat_session,
      tokens_input: 5, tokens_output: 3)

    allow(ChatSessions::SendMessage).to receive(:call) do |**kwargs|
      kwargs[:on_message_persisted]&.call(tool_result_msg)
      assistant_msg
    end

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Run tool",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_tool_result"))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_complete"))
  end

  it "broadcasts error for argument errors" do
    allow(ChatSessions::SendMessage).to receive(:call)
      .and_raise(ArgumentError, "chat session must be active")

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Hello",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "error", message: "chat session must be active"))
  end

  it "broadcasts error for token limit exceeded" do
    allow(ChatSessions::SendMessage).to receive(:call)
      .and_raise(ChatSessions::TokenLimitExceededError.new("limit reached", remaining: 0, limit: 100, limit_type: "session"))

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Hello",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "error", message: "limit reached"))
  end

  it "broadcasts generic error for unexpected failures" do
    allow(ChatSessions::SendMessage).to receive(:call)
      .and_raise(StandardError, "provider timeout")

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Hello",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "error", message: "An unexpected error occurred"))
  end

  it "broadcasts error and discards on missing session" do
    expect {
      described_class.perform_now(
        chat_session_id: -1,
        content: "Hello",
        stream_message_id: stream_message_id
      )
    }.not_to raise_error
  end
end
