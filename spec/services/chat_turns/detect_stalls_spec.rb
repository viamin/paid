# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalls do
  # @spec CHAT-TURN-001 CHAT-TURN-002 CHAT-TURN-003
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }

  it "marks an inactive unfinished turn stalled and writes a transcript notice" do
    turn = create(:chat_turn, chat_session: session, account:, actor: user, last_activity_at: 11.minutes.ago)

    expect { described_class.call }.to change { session.messages.where(role: "system").count }.by(1)

    expect(turn.reload.status).to eq("stalled")
    expect(session.messages.last).to be_stalled_turn_notice
  end

  it "does not stall a turn waiting for tool confirmation" do
    turn = create(:chat_turn, chat_session: session, account:, actor: user, last_activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    expect { described_class.call }.not_to change { session.messages.count }
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not stall a known long-running operation" do
    turn = create(:chat_turn, chat_session: session, account:, actor: user, last_activity_at: 11.minutes.ago,
      metadata: { "long_running_until" => 10.minutes.from_now.iso8601 })

    described_class.call

    expect(turn.reload.status).to eq("streaming")
  end
end
