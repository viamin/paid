# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Stall do
  # @spec CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-005
  it "marks an inactive turn stalled and creates one durable transcript notice" do
    chat_session = create(:chat_session)
    turn = create(:chat_turn, chat_session:, status: "streaming", last_activity_at: 11.minutes.ago)

    expect(described_class.call(chat_turn: turn)).to be true
    expect(turn.reload).to be_stalled
    notice = chat_session.messages.last
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("completion is unknown")
    expect(ApplicationController.render(partial: "chat_messages/message", locals: { message: notice }))
      .to include("Review transcript and retry")
    expect { described_class.call(chat_turn: turn) }.not_to change { chat_session.messages.count }
  end

  # @spec CHAT-TURN-RECOVERY-004
  it "does not stall a completed turn" do
    turn = create(:chat_turn, status: "completed", last_activity_at: 11.minutes.ago)

    expect(described_class.call(chat_turn: turn)).to be false
  end
end
