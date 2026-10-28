# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
  let(:session) { create(:chat_session) }

  it "marks an inactive streaming turn stalled and preserves a transcript notice" do
    turn = create(:chat_turn, chat_session: session, last_activity_at: 11.minutes.ago)

    expect { described_class.call }.to change { session.messages.where(role: "system").count }.by(1)

    expect(turn.reload).to have_attributes(status: "stalled", classification: "no_durable_activity")
    expect(session.messages.last).to be_stalled_turn_notice
  end

  it "does not classify a pending confirmation as stalled" do
    turn = create(:chat_turn, chat_session: session, last_activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    described_class.call

    expect(turn.reload.status).to eq("streaming")
  end

  it "does not classify a known rate-limit pause as stalled" do
    turn = create(:chat_turn, chat_session: session, last_activity_at: 11.minutes.ago)
    session.update!(rate_limited_until: 1.minute.from_now)

    described_class.call

    expect(turn.reload.status).to eq("streaming")
  end
end
