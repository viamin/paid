# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Chat turn recovery" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  before { sign_in user }

  # @spec CHAT-TURN-003
  it "requeues one explicitly confirmed stalled turn with no tool evidence" do
    turn = create(:chat_turn, chat_session:, status: "stalled", activity_at: 11.minutes.ago)

    expect {
      post resume_chat_session_chat_turn_path(chat_session, turn), params: { confirmed: true }
    }.to have_enqueued_job(ChatSessions::ProcessMessageJob)

    expect(turn.reload).to have_attributes(status: "streaming", recovery_attempts: 1)
  end

  it "refuses recovery when tool activity was recorded" do
    turn = create(:chat_turn, chat_session:, status: "stalled")
    create(:chat_message, :tool, chat_session:, tool_name: "trigger_agent_run")

    expect {
      post resume_chat_session_chat_turn_path(chat_session, turn), params: { confirmed: true }
    }.not_to have_enqueued_job(ChatSessions::ProcessMessageJob)

    expect(turn.reload.status).to eq("stalled")
  end
end
