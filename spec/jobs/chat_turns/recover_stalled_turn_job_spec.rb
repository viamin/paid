# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::RecoverStalledTurnJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session: chat_session, content: "Keep going") }
  let(:chat_turn) { create(:chat_turn, chat_session: chat_session, user_message: user_message) }
  let(:llm_response) do
    { content: "Picking back up.", tool_calls: [], tokens_input: 10, tokens_output: 5, model: "gpt-4o" }
  end

  before do
    allow(ChatSessions::BuildLlmClient).to receive(:call).and_return(instance_double(Proc, call: llm_response))
  end

  describe "#perform" do
    # @spec CHAT-TURN-RECOVERY-004
    it "resumes the turn and broadcasts the completion" do
      expect {
        described_class.perform_now(chat_turn_id: chat_turn.id, triggered_by: "automatic")
      }.to have_broadcasted_to("chat_session:#{chat_session.id}")
        .with(hash_including(type: "message_start"))

      expect(chat_turn.reload.status).to eq("completed")
    end

    it "logs and swallows an unexpected error instead of raising" do
      allow(ChatTurns::Resume).to receive(:call).and_raise(StandardError, "boom")

      expect {
        described_class.perform_now(chat_turn_id: chat_turn.id, triggered_by: "automatic")
      }.not_to raise_error
    end
  end
end
