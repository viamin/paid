# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Resume do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session: chat_session, content: "Keep going") }
  let(:chat_turn) { create(:chat_turn, :stalled, chat_session: chat_session, user_message: user_message) }
  let(:llm_response) do
    { content: "Picking back up.", tool_calls: [], tokens_input: 10, tokens_output: 5, model: "gpt-4o" }
  end
  let(:llm_client) { instance_double(Proc, call: llm_response) }

  describe ".call" do
    # @spec CHAT-TURN-RECOVERY-004
    it "resumes the agent loop against the already-persisted conversation without resending the user message" do
      chat_turn

      expect {
        described_class.call(chat_turn: chat_turn, llm_client: llm_client)
      }.not_to change { chat_session.messages.where(role: "user").count }

      expect(chat_session.messages.where(role: "assistant").last.content).to eq("Picking back up.")
    end

    it "completes the turn on a successful resume" do
      described_class.call(chat_turn: chat_turn, llm_client: llm_client)

      expect(chat_turn.reload.status).to eq("completed")
    end

    it "fails the turn and re-raises when the resumed loop raises" do
      allow(llm_client).to receive(:call).and_raise(AgentHarness::Error, "boom")

      expect {
        described_class.call(chat_turn: chat_turn, llm_client: llm_client)
      }.to raise_error(AgentHarness::Error)

      expect(chat_turn.reload.status).to eq("failed")
      expect(chat_turn.failure_classification).to eq("provider_error")
    end

    it "raises instead of resuming an archived session" do
      chat_session.update!(status: "archived")

      expect {
        described_class.call(chat_turn: chat_turn, llm_client: llm_client)
      }.to raise_error(ArgumentError, /archived/)
    end
  end
end
