# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ResumeRateLimited do
  # @spec CHAT-API-017
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user, rate_limited_until: 1.minute.ago) }

  before do
    create(:chat_message, chat_session: chat_session, role: "user", content: "Still there?")
    allow(Tools::Registry).to receive(:chat_definitions_for).and_return([])
  end

  describe ".call" do
    context "when the retried runner succeeds" do
      let(:llm_client) do
        Class.new do
          def call(conversation, tools: nil)
            @conversation = conversation
            { content: "Yes, still here.", tool_calls: [], tokens_input: 10, tokens_output: 5, model: "gpt-4o" }
          end
        end.new
      end

      it "clears the pause and resends the unanswered message without persisting a new user message" do
        expect {
          described_class.call(chat_session: chat_session, llm_client: llm_client)
        }.not_to change(chat_session.messages.where(role: "user"), :count)

        expect(chat_session.reload.rate_limited_until).to be_nil
      end

      it "returns the new assistant message" do
        message = described_class.call(chat_session: chat_session, llm_client: llm_client)

        expect(message.role).to eq("assistant")
        expect(message.content).to eq("Yes, still here.")
      end
    end

    context "when the retried runner is still rate limited" do
      let(:llm_client) do
        Class.new do
          def call(*)
            raise AgentHarness::RateLimitError.new("still limited", reset_time: 10.minutes.from_now)
          end
        end.new
      end

      it "re-pauses the session with the new reset time instead of raising" do
        result = described_class.call(chat_session: chat_session, llm_client: llm_client)

        expect(result).to be_nil
        expect(chat_session.reload).to be_rate_limited
      end

      it "persists a new pause notice" do
        expect {
          described_class.call(chat_session: chat_session, llm_client: llm_client)
        }.to change { chat_session.messages.where(role: "system").count }.by(1)
      end
    end
  end
end
