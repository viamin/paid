# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-API-026 CHAT-API-027
  let(:chat_session) { create(:chat_session) }

  it "marks an inactive partial turn stalled and persists one transcript notice" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.ago)
    create(:chat_message, chat_session:, chat_turn: turn, role: "user", content: "Do the thing")

    expect { described_class.call }.to change { chat_session.messages.where(role: "system").count }.by(1)
    expect(turn.reload).to have_attributes(status: "stalled", stalled_at: be_present)
    expect { described_class.call }.not_to change { chat_session.messages.where(role: "system").count }
  end

  it "does not stall an active pending confirmation" do
    turn = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.ago)
    create(:chat_message, chat_session:, chat_turn: turn, role: "assistant", content: nil,
      tool_name: "trigger_agent_run", tool_call_id: "call_1", tool_arguments: {}, tool_status: "pending")

    expect { described_class.call }.not_to change { turn.reload.status }
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not stall a known rate-limited session" do
    chat_session.update!(rate_limited_until: 5.minutes.from_now)
    turn = create(:chat_turn, chat_session:, last_activity_at: 11.minutes.ago)

    described_class.call

    expect(turn.reload.status).to eq("streaming")
  end
end
