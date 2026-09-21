# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::RecordProviderError do
  # @spec CHAT-API-017
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:error) { AgentHarness::ProviderError.new("provider unavailable") }

  describe ".call" do
    it "persists a system message flagged as a provider-error notice" do
      message = described_class.call(chat_session: chat_session, error: error)

      expect(message).to be_persisted
      expect(message.role).to eq("system")
      expect(message).to be_provider_error_notice
      expect(message.content).to include("provider unavailable")
    end

    it "appends the notice to the session's existing transcript" do
      create(:chat_message, chat_session: chat_session, role: "user", content: "Still there?")

      described_class.call(chat_session: chat_session, error: error)

      expect(chat_session.messages.last).to be_provider_error_notice
    end

    it "does not re-set the session's rate-limit window" do
      chat_session.update!(rate_limited_until: nil)

      described_class.call(chat_session: chat_session, error: error)

      expect(chat_session.reload.rate_limited_until).to be_nil
    end
  end
end
