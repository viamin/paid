# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob do
  # @spec CHAT-TURN-RECOVERY-001, CHAT-TURN-RECOVERY-002, CHAT-TURN-RECOVERY-003
  let(:session) { create(:chat_session) }

  it "marks an overdue streaming turn stalled and persists one transcript notice" do
    turn = create(:chat_turn, :streaming, chat_session: session, checkpointed_at: 11.minutes.ago)

    expect { described_class.new.perform }.to change { session.messages.where(role: "system").count }.by(1)

    expect(turn.reload).to be_stalled
    expect(turn.classified_at).to be_present
    expect(session.messages.last).to be_stalled_turn_notice
  end

  it "does not stall a turn waiting for user confirmation" do
    turn = create(:chat_turn, :streaming, chat_session: session, checkpointed_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    expect { described_class.new.perform }.not_to change { turn.reload.state }
  end

  # @spec CHAT-TURN-RECOVERY-004
  it "does not duplicate a notice or automatically replay a stalled turn when the sweep runs again" do
    turn = create(:chat_turn, :streaming, chat_session: session, checkpointed_at: 11.minutes.ago)

    2.times { described_class.new.perform }

    expect(session.messages.where("metadata ->> 'stalled_turn_notice' = 'true'").count).to eq(1)
    expect(turn.reload.recovery_attempts).to eq(0)
  end
end
