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

  it "calls SendMessage and broadcasts events" do
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
      .with(hash_including(type: "message_complete", message_id: stream_message_id))
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
