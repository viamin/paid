# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-003
  let(:chat_session) { create(:chat_session) }
  let(:user_message) { create(:chat_message, chat_session:) }

  it "starts streaming and completes only after an assistant response" do
    turn = described_class.start!(chat_session:, user_message:)

    expect(turn).to be_streaming
    expect(turn.completed?).to be false

    turn.complete!

    expect(turn).to be_completed
    expect(turn.completed_at).to be_present
  end

  it "records a stalled classification and creates only one notice" do
    confirmation = create(:chat_message, :tool_call, chat_session:, tool_status: "pending")
    turn = described_class.start!(chat_session:, user_message:)

    expect { turn.stall! }.to change { chat_session.messages.count }.by(1)
    expect { turn.stall! }.not_to change { chat_session.messages.count }

    notice = chat_session.messages.last
    expect(turn.reload).to be_stalled
    expect(turn.detected_at).to be_present
    expect(notice).to be_stalled_turn_notice
    expect(notice.metadata).to include("chat_turn_id" => turn.id)
    expect(notice.metadata).to include("pending_confirmation_ids" => [ confirmation.id ])
  end
end
