# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-API-026
  let(:chat_session) { create(:chat_session) }

  it "marks a silent streaming turn stalled and persists one actionable notice" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.ago)

    expect { described_class.call }.to change { chat_session.messages.system.count }.by(1)

    expect(turn.reload).to be_stalled
    notice = chat_session.messages.system.last
    expect(notice).to have_attributes(metadata: hash_including("chat_turn_stalled_notice" => true, "chat_turn_id" => turn.id))
  end

  it "does not stall a turn awaiting a tool confirmation" do
    turn = create(:chat_turn, chat_session:, state: "awaiting_confirmation", last_activity_at: 11.minutes.ago)

    expect { described_class.call }.not_to change { chat_session.messages.count }
    expect(turn.reload.state).to eq("awaiting_confirmation")
  end

  it "does not duplicate a notice after a concurrent or repeated sweep" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.ago)

    2.times { described_class.call }

    expect(turn.reload).to be_stalled
    expect(chat_session.messages.system.where("metadata ->> 'chat_turn_id' = ?", turn.id.to_s).count).to eq(1)
  end
end
