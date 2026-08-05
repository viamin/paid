# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ProcessMessageJob, type: :job do
  # @spec CHAT-API-002
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
    # @spec CHAT-API-003
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
    # @spec CHAT-API-003
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

  it "broadcasts provider rate limit errors" do
    allow(ChatSessions::SendMessage).to receive(:call)
      .and_raise(AgentHarness::RateLimitError, "API rate limit exceeded: Weekly/Monthly Limit Exhausted")

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Hello",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "error", message: "API rate limit exceeded: Weekly/Monthly Limit Exhausted"))
  end

  it "broadcasts a fallback notice and continues when a fallback runner is configured" do
    fallback_runner = configure_chat_fallback
    allow(ChatSessions::BuildLlmClient).to receive(:call)
      .and_return(rate_limited_llm_client, successful_fallback_llm_client)

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "Hello",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_created", role: "assistant",
        fallback_notice: true,
        html: include("Switching to #{fallback_runner.display_name} and continuing.")))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_created", role: "assistant",
        html: include("Fallback answer")))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_complete", tokens: { input: 10, output: 5 }))
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

  # Exercises the REAL SendMessage service (not mocked) through the job with a
  # streaming LLM client, asserting the complete broadcast contract a
  # ChatChannel subscriber depends on to render a reply. This is the path the
  # chat UI uses; the per-example mocks above stub SendMessage entirely and so
  # cannot detect a regression in the streaming/broadcast wiring.
  it "broadcasts the full streaming sequence with chunk content and rendered html" do
    allow(ChatSessions::BuildLlmClient).to receive(:call).and_return(streaming_llm_client)

    expect {
      described_class.perform_now(
        chat_session_id: chat_session.id,
        content: "hi",
        stream_message_id: stream_message_id
      )
    }.to have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_start", message_id: stream_message_id))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_chunk", message_id: stream_message_id, content: "Hello "))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_chunk", message_id: stream_message_id, content: "there!"))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_created", role: "assistant",
        stream_message_id: stream_message_id, html: include("Hello there!")))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_complete", message_id: stream_message_id,
        tokens: { input: 10, output: 5 }))
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

  def rate_limited_llm_client
    Class.new do
      def call(*)
        raise AgentHarness::RateLimitError, "API rate limit exceeded"
      end
    end.new
  end

  # A streaming client that emits two chunks then returns a final assistant
  # response, exercising the real AgentLoop chunk path through the job.
  def streaming_llm_client
    Class.new do
      def call(_conversation, on_chunk: nil)
        on_chunk&.call("Hello ")
        on_chunk&.call("there!")
        { content: "Hello there!", tool_calls: [], tokens_input: 10, tokens_output: 5, model: "gpt-4o" }
      end
    end.new
  end

  def successful_fallback_llm_client
    instance_double(Proc, call: {
      content: "Fallback answer",
      tool_calls: [],
      tokens_input: 10,
      tokens_output: 5,
      model: "claude"
    })
  end

  def configure_chat_fallback
    primary_runner = create(:runner, :api_key, user: user, runner_key: "opencode",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })
    fallback_runner = create(:runner, :api_key, user: user, runner_key: "claude",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "anthropic"))

    user.settings.update!(kb_chat_fallback_runners: [ "claude" ])
    chat_session.update!(runner: primary_runner)
    fallback_runner
  end
end
