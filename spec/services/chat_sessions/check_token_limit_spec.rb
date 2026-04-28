# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::CheckTokenLimit do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  describe ".call" do
    context "without tenant settings" do
      it "returns within limit with nil limits" do
        result = described_class.call(chat_session: chat_session)

        expect(result[:within_limit]).to be true
        expect(result[:remaining_tokens]).to be_nil
        expect(result[:limit]).to be_nil
      end
    end

    context "with session token limit" do
      before do
        create(:tenant_setting, account: account,
          features: { "chat_settings" => { "chat_session_token_limit" => 1000 } })
      end

      it "returns within limit when under the limit" do
        create(:chat_message, :assistant, chat_session: chat_session, tokens_input: 200, tokens_output: 100)

        result = described_class.call(chat_session: chat_session)

        expect(result[:within_limit]).to be true
        expect(result[:remaining_tokens]).to eq(700)
        expect(result[:limit]).to eq(1000)
        expect(result[:limit_type]).to eq("session")
      end

      it "returns exceeded when at the limit" do
        create(:chat_message, :assistant, chat_session: chat_session, tokens_input: 600, tokens_output: 400)

        result = described_class.call(chat_session: chat_session)

        expect(result[:within_limit]).to be false
        expect(result[:remaining_tokens]).to eq(0)
        expect(result[:limit]).to eq(1000)
      end

      it "returns exceeded when over the limit" do
        create(:chat_message, :assistant, chat_session: chat_session, tokens_input: 800, tokens_output: 500)

        result = described_class.call(chat_session: chat_session)

        expect(result[:within_limit]).to be false
        expect(result[:remaining_tokens]).to eq(0)
      end
    end

    context "with monthly token limit" do
      before do
        create(:tenant_setting, account: account,
          features: { "chat_settings" => {
            "chat_session_token_limit" => nil,
            "chat_monthly_token_limit" => 5000
          } })
      end

      it "counts tokens across all sessions in the account this month" do
        other_session = create(:chat_session, account: account, created_by: user)

        create(:token_usage, :chat, chat_session: chat_session,
          input_tokens: 1000, output_tokens: 500)
        create(:token_usage, :chat, chat_session: other_session,
          input_tokens: 1000, output_tokens: 500)

        result = described_class.call(chat_session: chat_session)

        expect(result[:within_limit]).to be true
        expect(result[:remaining_tokens]).to eq(2000)
        expect(result[:limit_type]).to eq("monthly")
      end

      it "returns exceeded when monthly limit reached" do
        create(:token_usage, :chat, chat_session: chat_session,
          input_tokens: 3000, output_tokens: 2000)

        result = described_class.call(chat_session: chat_session)

        expect(result[:within_limit]).to be false
        expect(result[:remaining_tokens]).to eq(0)
      end
    end

    context "with both session and monthly limits" do
      before do
        create(:tenant_setting, account: account,
          features: { "chat_settings" => {
            "chat_session_token_limit" => 500,
            "chat_monthly_token_limit" => 10_000
          } })
      end

      it "returns the more restrictive limit" do
        create(:chat_message, :assistant, chat_session: chat_session, tokens_input: 200, tokens_output: 100)

        result = described_class.call(chat_session: chat_session)

        expect(result[:limit_type]).to eq("session")
        expect(result[:remaining_tokens]).to eq(200)
      end
    end
  end
end
