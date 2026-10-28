# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::StallSweepJob do
  # @spec CHAT-TURN-002
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:session) { create(:chat_session, account:, created_by: actor) }

  it "marks an inactive turn stalled and creates a durable transcript notice" do
    user_message = create(:chat_message, chat_session: session)
    turn = create(:chat_turn, chat_session: session, actor:, user_message:, status: "streaming", last_activity_at: 11.minutes.ago)

    described_class.perform_now

    expect(turn.reload.status).to eq("stalled")
    expect(session.messages.last).to be_stalled_turn_notice
  end

  it "does not mark a pending confirmation stalled" do
    user_message = create(:chat_message, chat_session: session)
    create(:chat_turn, chat_session: session, actor:, user_message:, status: "streaming", last_activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    described_class.perform_now

    expect(ChatTurn.last.status).to eq("streaming")
    expect(session.messages.where("metadata ->> 'stalled_turn_notice' = 'true'")).not_to exist
  end
end
