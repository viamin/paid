# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Stall do
  # @spec CHAT-TURN-002 CHAT-TURN-003
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }

  it "marks an inactive streaming turn stalled and preserves an actionable notice" do
    turn = create(:chat_turn, chat_session: session, last_activity_at: 20.minutes.ago)

    described_class.call(turn:)

    notice = session.messages.last
    expect(turn.reload).to have_attributes(status: "stalled", classification: "no_durable_activity")
    expect(notice).to be_stalled_turn_notice
    expect(notice.metadata).to include("chat_turn_id" => turn.id, "resumable" => true)
  end

  it "does not stall a turn awaiting an explicit tool confirmation" do
    turn = create(:chat_turn, chat_session: session, last_activity_at: 20.minutes.ago)
    create(:chat_message, chat_session: session, role: "assistant", content: nil,
      tool_name: "trigger_agent_run", tool_status: "pending")

    described_class.call(turn:)

    expect(turn.reload.status).to eq("streaming")
    expect(session.messages.stalled_turn_notices).to be_empty
  end
end
