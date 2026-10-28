# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalls do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  # @spec CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-004
  it "marks an inactive streaming turn stalled and preserves an explicit transcript notice" do
    user_message = create(:chat_message, chat_session:, role: "user", content: "Deploy this")
    turn = create(:chat_turn, chat_session:, user_message:, state: "streaming", last_activity_at: 16.minutes.ago)

    expect(described_class.call).to contain_exactly(turn)

    expect(turn.reload).to have_attributes(state: "stalled", user_message: user_message)
    notice = chat_session.messages.find_by("metadata ->> 'chat_turn_id' = ?", turn.id.to_s)
    expect(notice).to be_present
    expect(notice.content).to include("No assistant completion was recorded")
    expect(notice.metadata).to include("chat_turn_stalled_notice" => true)
  end

  # @spec CHAT-TURN-RECOVERY-003
  it "does not reclassify terminal work or a turn still within its activity window" do
    completed = create(:chat_turn, chat_session:, state: "completed", last_activity_at: 1.hour.ago)
    active = create(:chat_turn, chat_session:, state: "streaming", last_activity_at: 5.minutes.ago)

    expect(described_class.call).to be_empty
    expect(completed.reload.state).to eq("completed")
    expect(active.reload.state).to eq("streaming")
  end

  # @spec CHAT-TURN-RECOVERY-003
  it "does not label an awaiting human confirmation as a stalled turn" do
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending")
    turn = create(:chat_turn, chat_session:, state: "streaming", last_activity_at: 16.minutes.ago)

    expect(described_class.call).to be_empty
    expect(turn.reload.state).to eq("streaming")
  end

  # @spec CHAT-TURN-RECOVERY-003
  it "makes duplicate sweeps idempotent" do
    turn = create(:chat_turn, chat_session:, state: "pending", last_activity_at: 16.minutes.ago)

    described_class.call

    expect(described_class.call).to be_empty
    expect(chat_session.messages.where("metadata ->> 'chat_turn_id' = ?", turn.id.to_s).count).to eq(1)
  end
end
