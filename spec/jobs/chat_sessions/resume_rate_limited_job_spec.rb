# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ResumeRateLimitedJob, type: :job do
  # @spec CHAT-API-017
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:chat_session) do
    create(:chat_session, account: account, created_by: user, rate_limited_until: 1.minute.ago)
  end
  let(:stream_name) { "chat_session:#{chat_session.id}" }

  before do
    create(:chat_message, chat_session: chat_session, role: "user", content: "Still there?")
  end

  it "resumes the session and broadcasts the new assistant message" do
    assistant_msg = create(:chat_message, :assistant, chat_session: chat_session)
    allow(ChatSessions::ResumeRateLimited).to receive(:call).and_return(assistant_msg)

    described_class.perform_now(chat_session_id: chat_session.id)

    expect(ChatSessions::ResumeRateLimited).to have_received(:call).with(hash_including(chat_session: chat_session))
  end

  it "broadcasts message_start and message_complete" do
    assistant_msg = create(:chat_message, :assistant, chat_session: chat_session,
      tokens_input: 8, tokens_output: 4)
    allow(ChatSessions::ResumeRateLimited).to receive(:call).and_return(assistant_msg)

    expect {
      described_class.perform_now(chat_session_id: chat_session.id)
    }.to have_broadcasted_to(stream_name).with(hash_including(type: "message_start"))
      .and have_broadcasted_to(stream_name)
      .with(hash_including(type: "message_complete", tokens: { input: 8, output: 4 }))
  end

  it "clears the pause so the session is no longer rate limited" do
    allow(ChatSessions::ResumeRateLimited).to receive(:call) do
      chat_session.clear_rate_limit!
      create(:chat_message, :assistant, chat_session: chat_session)
    end

    described_class.perform_now(chat_session_id: chat_session.id)

    expect(chat_session.reload).not_to be_rate_limited
  end

  it "does nothing when the session's rate limit window has not elapsed yet" do
    chat_session.update!(rate_limited_until: 1.hour.from_now)
    allow(ChatSessions::ResumeRateLimited).to receive(:call)

    described_class.perform_now(chat_session_id: chat_session.id)

    expect(ChatSessions::ResumeRateLimited).not_to have_received(:call)
  end

  it "does nothing when the session is no longer rate limited" do
    chat_session.clear_rate_limit!
    allow(ChatSessions::ResumeRateLimited).to receive(:call)

    described_class.perform_now(chat_session_id: chat_session.id)

    expect(ChatSessions::ResumeRateLimited).not_to have_received(:call)
  end

  it "does not raise when the session no longer exists" do
    expect {
      described_class.perform_now(chat_session_id: -1)
    }.not_to raise_error
  end

  it "logs and swallows unexpected errors instead of raising" do
    allow(ChatSessions::ResumeRateLimited).to receive(:call).and_raise(StandardError, "boom")

    expect {
      described_class.perform_now(chat_session_id: chat_session.id)
    }.not_to raise_error
  end
end
