# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ResumeStalledTurn do
  # @spec CHAT-API-027
  let(:chat_session) { create(:chat_session) }
  let(:user) { chat_session.created_by }
  let(:turn) { create(:chat_turn, chat_session:, state: "stalled", stalled_at: Time.current) }
  let(:client) { instance_double(Proc, call: { content: "Recovered answer", tool_calls: [], tokens_input: 1, tokens_output: 1 }) }

  it "resumes from the existing user message and records the outcome" do
    turn.user_message

    expect {
      described_class.call(chat_turn: turn, actor: user, llm_client: client)
    }.not_to change { chat_session.messages.where(role: "user").count }

    expect(turn.reload).to be_completed
    expect(turn.events.order(:id).pluck(:event_type)).to include("recovery_started", "recovery_completed")
  end

  it "deduplicates repeated recovery attempts" do
    described_class.call(chat_turn: turn, actor: user, llm_client: client)

    expect {
      described_class.call(chat_turn: turn, actor: user, llm_client: client)
    }.to raise_error(described_class::RecoveryConflictError)

    expect(turn.events.order(:id).last.event_type).to eq("recovery_deduplicated")
  end
end
