# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-TURN-RECOVERY-002
  let(:account) { create(:account) }
  let(:session) { create(:chat_session, account: account) }
  let(:message) { create(:chat_message, chat_session: session) }

  it "marks an inactive streaming turn stalled and preserves a transcript notice" do
    turn = ChatTurn.create!(chat_session: session, user_message: message, status: "streaming", last_activity_at: 11.minutes.ago)

    described_class.call(now: Time.current)

    expect(turn.reload).to have_attributes(status: "stalled", failure_classification: nil)
    notice = session.messages.order(:id).last
    expect(notice).to be_stalled_turn_notice
    expect(notice.metadata).to include("chat_turn_id" => turn.id, "side_effecting_tools_completed" => false)
  end

  it "does not mark a confirmation pause or rate-limited session stalled" do
    waiting = ChatTurn.create!(chat_session: session, user_message: message, status: "waiting_for_confirmation", last_activity_at: 1.hour.ago)
    limited_session = create(:chat_session, account: account, rate_limited_until: 1.hour.from_now)
    limited_message = create(:chat_message, chat_session: limited_session)
    active = ChatTurn.create!(chat_session: limited_session, user_message: limited_message, status: "streaming", last_activity_at: 1.hour.ago)

    described_class.call(now: Time.current)

    expect(waiting.reload.status).to eq("waiting_for_confirmation")
    expect(active.reload.status).to eq("streaming")
  end
end
