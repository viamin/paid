# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::Archive do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe ".call" do
    it "does not append a stopped-capability notice during intentional teardown" do
      chat_session = create(:chat_session, :workspace, account: account, created_by: user)
      create(:chat_message, chat_session: chat_session)

      described_class.call(chat_session: chat_session)

      chat_session.reload
      expect(chat_session.status).to eq("archived")
      expect(chat_session.messages.container_capability_notices).to be_empty
      expect(chat_session.metadata["total_messages"]).to eq(1)
    end
  end
end
