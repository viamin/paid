# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::MarkRateLimited do
  # @spec CHAT-API-017
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  describe ".call" do
    it "records the reset time reported by the error on the session" do
      reset_at = 10.minutes.from_now
      error = AgentHarness::RateLimitError.new("rate limited", reset_time: reset_at)

      described_class.call(chat_session: chat_session, error: error)

      expect(chat_session.reload.rate_limited_until).to be_within(1.second).of(reset_at)
    end

    it "falls back to the default reset window when the error reports no reset time" do
      error = AgentHarness::RateLimitError.new("rate limited")

      described_class.call(chat_session: chat_session, error: error)

      expect(chat_session.reload.rate_limited_until)
        .to be_within(1.second).of(ChatSession::RATE_LIMIT_DEFAULT_RESET.from_now)
    end

    it "persists a system message explaining the pause" do
      error = AgentHarness::RateLimitError.new("rate limited", reset_time: 5.minutes.from_now)

      message = described_class.call(chat_session: chat_session, error: error)

      expect(message).to be_persisted
      expect(message.role).to eq("system")
      expect(message).to be_rate_limit_paused
    end

    it "notes automatic resend is disabled when the account opted out" do
      create(:tenant_setting, account: account, features: { "chat_settings" => { "chat_auto_resume_rate_limited" => false } })
      error = AgentHarness::RateLimitError.new("rate limited")

      message = described_class.call(chat_session: chat_session, error: error)

      expect(message.content).to include("Automatic resend is disabled")
      expect(message.metadata["auto_resume"]).to be(false)
    end
  end
end
