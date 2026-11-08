# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::Unarchive do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user, status: "archived") }

  describe ".call" do
    it "restores an archived session to active" do
      restored = described_class.call(chat_session: chat_session)

      expect(restored.status).to eq("active")
      expect(restored.idle_timeout_at).to be_within(5.seconds).of(30.minutes.from_now)
      expect(restored.metadata["unarchived_at"]).to be_present
    end

    it "raises when the session is not archived" do
      chat_session.update!(status: "active")

      expect {
        described_class.call(chat_session: chat_session)
      }.to raise_error(ArgumentError, /must be archived/)
    end

    # @spec CHAT-API-030
    it "discards the fresh blank draft when restoring an archived blank draft" do
      original = ChatSessions::Create.call(account: account, user: user)
      ChatSessions::Archive.call(chat_session: original)
      replacement = ChatSessions::Create.call(account: account, user: user)

      restored = described_class.call(chat_session: original)

      expect(restored).to eq(original)
      expect(restored.reload.status).to eq("active")
      expect(ChatSession.unstarted_untitled_personal.where(created_by: user)).to contain_exactly(restored)
      expect { replacement.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    # @spec CHAT-API-030
    it "cleans up a container-backed fresh draft before discarding it" do
      original = ChatSessions::Create.call(account: account, user: user)
      ChatSessions::Archive.call(chat_session: original)
      replacement = ChatSessions::Create.call(account: account, user: user, container_capability: "pending")
      replacement.update!(container_capability: "ready", container_id: "container-123", workspace_volume: "volume-123")
      allow(Rails.logger).to receive(:info).and_call_original

      described_class.call(chat_session: original)

      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "chat_session.cleanup_container", chat_session_id: replacement.id)
      )
      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "chat_session.cleanup_volume", chat_session_id: replacement.id)
      )
      expect { replacement.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    # @spec CHAT-API-030
    it "keeps the fresh draft when restoring a started archived session" do
      started = ChatSessions::Create.call(account: account, user: user)
      started.messages.create!(role: "user", content: "Start this chat")
      ChatSessions::Archive.call(chat_session: started)
      replacement = ChatSessions::Create.call(account: account, user: user)

      restored = described_class.call(chat_session: started)

      expect(restored.reload.status).to eq("active")
      expect(ChatSession.unstarted_untitled_personal.where(created_by: user)).to contain_exactly(replacement)
    end
  end
end
