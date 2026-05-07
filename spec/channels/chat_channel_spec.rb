# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatChannel do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  before do
    stub_connection current_user: user
  end

  describe "#subscribed" do
    it "subscribes to the chat session stream" do
      subscribe(session_id: chat_session.id)
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("chat_session:#{chat_session.id}")
    end

    it "rejects subscription for non-existent session" do
      subscribe(session_id: -1)
      expect(subscription).to be_rejected
    end

    it "rejects subscription for another account's session" do
      other_account = create(:account)
      other_session = create(:chat_session, account: other_account)

      subscribe(session_id: other_session.id)
      expect(subscription).to be_rejected
    end
  end

  describe "#send_message" do
    before do
      subscribe(session_id: chat_session.id)
    end

    it "broadcasts message_start and enqueues the job" do
      expect(ChatSessions::ProcessMessageJob).to receive(:perform_later).with(
        hash_including(chat_session_id: chat_session.id, content: "Hello")
      )

      expect {
        perform :send_message, content: "Hello"
      }.to have_broadcasted_to("chat_session:#{chat_session.id}")
        .with(hash_including(type: "message_start"))
    end

    it "ignores blank content" do
      expect(ChatSessions::ProcessMessageJob).not_to receive(:perform_later)
      perform :send_message, content: ""
    end

    it "rejects users who cannot create chat messages" do
      viewer = create(:user, :viewer, account: account)

      stub_connection current_user: viewer
      subscribe(session_id: chat_session.id)

      expect(ChatSessions::ProcessMessageJob).not_to receive(:perform_later)

      expect {
        perform :send_message, content: "Hello"
      }.not_to have_broadcasted_to("chat_session:#{chat_session.id}")

      expect(transmissions.last).to include("type" => "error", "message" => "You are not authorized to send messages")
    end

    it "enforces the per-user per-session rate limit" do
      allow(ChatMessages::RateLimit).to receive(:exceeded?).and_return(true)

      expect(ChatSessions::ProcessMessageJob).not_to receive(:perform_later)

      expect {
        perform :send_message, content: "Hello"
      }.not_to have_broadcasted_to("chat_session:#{chat_session.id}")

      expect(transmissions.last).to include("type" => "error", "message" => "Rate limit exceeded")
    end

    it "rejects content exceeding maximum length" do
      long_content = "x" * (ChatSessions::SendMessage::MAX_CONTENT_LENGTH + 1)

      expect(ChatSessions::ProcessMessageJob).not_to receive(:perform_later)

      perform :send_message, content: long_content

      expect(transmissions.last).to include("type" => "error", "message" => "Message exceeds maximum length")
    end
  end
end
