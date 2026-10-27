# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Lifecycle do
  # @spec CHAT-TURN-RECOVERY-001, CHAT-TURN-RECOVERY-002
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  it "marks an inactive streaming turn stalled and persists a visible notice" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.ago)

    result = described_class.stall!(turn:)

    expect(result).to eq(turn)
    expect(turn.reload.status).to eq("stalled")
    notice = chat_session.messages.find_by("metadata ->> 'chat_turn_id' = ?", turn.id.to_s)
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("without a final assistant response")
  end

  it "does not stall a turn awaiting a confirmation" do
    turn = create(:chat_turn, chat_session:, status: "awaiting_confirmation", last_activity_at: 11.minutes.ago)

    expect(described_class.stall!(turn:)).to be_nil
    expect(turn.reload.status).to eq("awaiting_confirmation")
  end
end
