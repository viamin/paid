# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::Close do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  describe ".call" do
    it "destroys sessions with no user messages" do
      session = create(:chat_session, account: account, created_by: user)
      create(:chat_message, :system, chat_session: session)

      expect {
        described_class.call(chat_session: session)
      }.to change(ChatSession, :count).by(-1)
    end

    it "transitions session to closed when user messages exist" do
      create(:chat_message, chat_session: chat_session)
      described_class.call(chat_session: chat_session)

      expect(chat_session.reload.status).to eq("closed")
    end

    it "computes token totals in metadata" do
      create(:chat_message, chat_session: chat_session)
      create(:token_usage, :chat, chat_session: chat_session, input_tokens: 100, output_tokens: 50)
      create(:token_usage, :chat, chat_session: chat_session, input_tokens: 200, output_tokens: 75)

      described_class.call(chat_session: chat_session)

      metadata = chat_session.reload.metadata
      expect(metadata["total_tokens_input"]).to eq(300)
      expect(metadata["total_tokens_output"]).to eq(125)
    end

    it "records total message count" do
      create(:chat_message, :system, chat_session: chat_session)
      create(:chat_message, chat_session: chat_session)
      create(:chat_message, :assistant, chat_session: chat_session)

      described_class.call(chat_session: chat_session)

      expect(chat_session.reload.metadata["total_messages"]).to eq(3)
    end

    it "records closed_at timestamp" do
      create(:chat_message, chat_session: chat_session)
      freeze_time do
        described_class.call(chat_session: chat_session)

        expect(chat_session.reload.metadata["closed_at"]).to eq(Time.current.iso8601)
      end
    end

    it "allows closing idle sessions" do
      idle_session = create(:chat_session, :idle, account: account, created_by: user)
      create(:chat_message, chat_session: idle_session)

      described_class.call(chat_session: idle_session)

      expect(idle_session.reload.status).to eq("closed")
    end

    it "raises when session is already closed" do
      closed_session = create(:chat_session, :closed, account: account, created_by: user)

      expect {
        described_class.call(chat_session: closed_session)
      }.to raise_error(ArgumentError, /active or idle/)
    end

    it "clears container_id for workspace sessions" do
      ws_session = create(:chat_session, :workspace, account: account, created_by: user)
      create(:chat_message, chat_session: ws_session)

      described_class.call(chat_session: ws_session)

      expect(ws_session.reload.container_id).to be_nil
      expect(ws_session.container_capability).to eq("stopped")
      expect(ws_session.workspace_volume).to be_nil
    end

    it "clears container_id when destroying empty workspace sessions" do
      ws_session = create(:chat_session, :workspace, account: account, created_by: user)

      described_class.call(chat_session: ws_session)

      expect { ws_session.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
