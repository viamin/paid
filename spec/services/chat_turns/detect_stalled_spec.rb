# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-API-027 CHAT-API-028
  it "marks an inactive in-progress turn stalled and preserves an actionable transcript notice" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session, content: "Deploy it")
    turn = ChatTurn.create!(chat_session: session, user_message:, state: "streaming", activity_at: 11.minutes.ago)

    described_class.call

    expect(turn.reload).to have_attributes(state: "stalled", classification: "inactivity")
    notice = session.messages.last
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("no unfinished action was assumed successful")
  end

  it "does not mark a pending confirmation or rate-limited turn stalled" do
    session = create(:chat_session, rate_limited_until: 5.minutes.from_now)
    user_message = create(:chat_message, chat_session: session)
    turn = ChatTurn.create!(chat_session: session, user_message:, state: "awaiting_confirmation", activity_at: 11.minutes.ago)

    described_class.call

    expect(turn.reload.state).to eq("awaiting_confirmation")
  end
end
