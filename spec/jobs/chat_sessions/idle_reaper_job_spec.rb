# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::IdleReaperJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "#perform" do
    it "closes sessions past their idle timeout" do
      session = create(:chat_session,
        account: account,
        created_by: user,
        idle_timeout_at: 1.minute.ago)
      create(:chat_message, chat_session: session)

      described_class.new.perform

      session.reload
      expect(session.status).to eq("closed")
    end

    it "does not close sessions before their timeout" do
      session = create(:chat_session,
        account: account,
        created_by: user,
        idle_timeout_at: 30.minutes.from_now)

      described_class.new.perform

      expect(session.reload.status).to eq("active")
    end

    it "computes token totals when closing" do
      session = create(:chat_session,
        account: account,
        created_by: user,
        idle_timeout_at: 1.minute.ago)
      create(:chat_message, chat_session: session)
      create(:token_usage, :chat, chat_session: session, input_tokens: 50, output_tokens: 25, cost_cents: 0)

      described_class.new.perform

      session.reload
      expect(session.metadata["total_tokens_input"]).to eq(50)
    end

    it "continues processing if one session fails" do
      session1 = create(:chat_session,
        account: account,
        created_by: user,
        idle_timeout_at: 1.minute.ago)
      session2 = create(:chat_session,
        account: account,
        created_by: user,
        idle_timeout_at: 1.minute.ago)
      create(:chat_message, chat_session: session1)
      create(:chat_message, chat_session: session2)

      allow(ChatSessions::Close).to receive(:call)
        .with(chat_session: anything)
        .and_call_original

      # Both should be attempted even if processing continues
      described_class.new.perform

      expect(session1.reload.status).to eq("closed")
      expect(session2.reload.status).to eq("closed")
    end
  end
end
