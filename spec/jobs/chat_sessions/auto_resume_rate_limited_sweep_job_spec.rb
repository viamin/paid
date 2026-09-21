# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::AutoResumeRateLimitedSweepJob do
  # @spec CHAT-API-017
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "#perform" do
    it "enqueues a resume job for sessions whose rate limit window has elapsed" do
      due = create(:chat_session, account: account, created_by: user, rate_limited_until: 1.minute.ago)

      expect { described_class.new.perform }
        .to have_enqueued_job(ChatSessions::ResumeRateLimitedJob).with(chat_session_id: due.id)
    end

    it "does not enqueue sessions still within their rate limit window" do
      create(:chat_session, account: account, created_by: user, rate_limited_until: 1.hour.from_now)

      expect { described_class.new.perform }
        .not_to have_enqueued_job(ChatSessions::ResumeRateLimitedJob)
    end

    it "does not enqueue sessions that were never rate limited" do
      create(:chat_session, account: account, created_by: user)

      expect { described_class.new.perform }
        .not_to have_enqueued_job(ChatSessions::ResumeRateLimitedJob)
    end

    it "skips accounts that opted out of automatic resumption" do
      create(:tenant_setting, account: account, features: { "chat_settings" => { "chat_auto_resume_rate_limited" => false } })
      create(:chat_session, account: account, created_by: user, rate_limited_until: 1.minute.ago)

      expect { described_class.new.perform }
        .not_to have_enqueued_job(ChatSessions::ResumeRateLimitedJob)
    end
  end
end
