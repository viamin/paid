# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::Turns::DetectStalled do
  # @spec CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-004 CHAT-TURN-RECOVERY-005 CHAT-TURN-RECOVERY-012
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:message) { create(:chat_message, chat_session: session) }
  let(:turn) { ChatSessions::Turns::Open.call(chat_session: session, user_message: message) }

  it "marks an inactive open turn stalled and writes a durable notice" do
    turn.update!(last_activity_at: 6.minutes.ago)

    described_class.call(turn:)

    expect(turn.reload).to have_attributes(status: "stalled", failure_classification: "unknown")
    expect(turn.events.find_by(event_type: "stall_detected")).to be_present
    expect(session.messages.last).to be_stalled_turn_notice
  end

  it "does not stall a turn that is awaiting confirmation" do
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")
    turn.update!(last_activity_at: 6.minutes.ago)

    described_class.call(turn:)

    expect(turn.reload.status).to eq("pending")
  end
end
