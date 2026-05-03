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

    it "broadcasts message events" do
      assistant_msg = create(:chat_message, :assistant, chat_session: chat_session,
        tokens_input: 10, tokens_output: 5)
      allow(ChatSessions::SendMessage).to receive(:call).and_return(assistant_msg)

      expect {
        perform :send_message, content: "Hello"
      }.to have_broadcasted_to("chat_session:#{chat_session.id}")
        .with(hash_including(type: "message_start"))
    end

    it "broadcasts persisted messages for user, assistant, and tool entries" do
      allow(ChatSessions::SendMessage).to receive(:call) do |**args|
        user_message = create(:chat_message, chat_session: chat_session, role: "user", content: "Hello")
        assistant_message = create(:chat_message, :assistant, chat_session: chat_session,
          content: "Let me check.", tokens_input: 10, tokens_output: 5)
        tool_message = create(:chat_message, :tool, chat_session: chat_session,
          tool_name: "search", tool_result: { status: "ok" }, tool_call_id: "call_1")

        args[:on_message_persisted].call(user_message)
        args[:on_message_persisted].call(assistant_message, stream_message_id: args[:stream_message_id])
        args[:on_message_persisted].call(tool_message)
        assistant_message
      end

      expect {
        perform :send_message, content: "Hello"
      }.to have_broadcasted_to("chat_session:#{chat_session.id}")
        .with(hash_including(type: "message_created", role: "user", stream_message_id: nil))
        .and have_broadcasted_to("chat_session:#{chat_session.id}")
          .with(hash_including(type: "message_created", role: "assistant", stream_message_id: kind_of(String)))
        .and have_broadcasted_to("chat_session:#{chat_session.id}")
          .with(hash_including(type: "message_created", role: "tool", stream_message_id: nil))
    end

    it "broadcasts streamed chunks before completion" do
      allow(ChatSessions::SendMessage).to receive(:call) do |**args|
        args[:on_chunk].call("I can ")
        args[:on_chunk].call("help.")

        create(:chat_message, :assistant, chat_session: chat_session,
          content: "I can help.", tokens_input: 10, tokens_output: 5)
      end

      expect {
        perform :send_message, content: "Hello"
      }.to have_broadcasted_to("chat_session:#{chat_session.id}")
        .with(hash_including(type: "message_chunk", content: "I can "))
        .and have_broadcasted_to("chat_session:#{chat_session.id}")
          .with(hash_including(type: "message_chunk", content: "help."))
    end

    it "ignores blank content" do
      expect(ChatSessions::SendMessage).not_to receive(:call)
      perform :send_message, content: ""
    end

    it "rejects users who cannot create chat messages" do
      viewer = create(:user, :viewer, account: account)

      stub_connection current_user: viewer
      subscribe(session_id: chat_session.id)

      expect(ChatSessions::SendMessage).not_to receive(:call)

      expect {
        perform :send_message, content: "Hello"
      }.not_to have_broadcasted_to("chat_session:#{chat_session.id}")

      expect(transmissions.last).to include("type" => "error", "message" => "You are not authorized to send messages")
    end

    it "enforces the per-user per-session rate limit" do
      allow(ChatMessages::RateLimit).to receive(:exceeded?).and_return(true)

      expect(ChatSessions::SendMessage).not_to receive(:call)

      expect {
        perform :send_message, content: "Hello"
      }.not_to have_broadcasted_to("chat_session:#{chat_session.id}")

      expect(transmissions.last).to include("type" => "error", "message" => "Rate limit exceeded")
    end

    it "broadcasts a generic error for unexpected failures" do
      allow(ChatSessions::SendMessage).to receive(:call)
        .and_raise(StandardError, "provider failed")

      perform :send_message, content: "Hello"

      expect(broadcasts("chat_session:#{chat_session.id}").map { |payload| payload["type"] }).not_to include("error")
      expect(transmissions.last).to include("type" => "error", "message" => "An unexpected error occurred")
    end

    it "broadcasts the original message for argument errors" do
      allow(ChatSessions::SendMessage).to receive(:call)
        .and_raise(ArgumentError, "chat session must be active")

      perform :send_message, content: "Hello"

      expect(broadcasts("chat_session:#{chat_session.id}").map { |payload| payload["type"] }).not_to include("error")
      expect(transmissions.last).to include("type" => "error", "message" => "chat session must be active")
    end
  end
end
