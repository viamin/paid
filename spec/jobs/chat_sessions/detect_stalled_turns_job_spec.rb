# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob do
  # @spec CHAT-TURN-002, CHAT-TURN-004
  it "marks inactive streaming turns stalled and persists a warning notice" do
    session = create(:chat_session)
    message = create(:chat_message, chat_session: session)
    turn = create(:chat_turn, chat_session: session, initiating_message: message, status: "streaming", last_activity_at: 11.minutes.ago)

    described_class.new.perform

    expect(turn.reload).to have_attributes(status: "stalled", failure_classification: "no_durable_activity")
    expect(turn.metadata).to include("stall_detected_at" => a_kind_of(String), "side_effecting_tools_completed" => false)
    expect(session.messages.last).to be_stalled_turn_notice
  end

  # @spec CHAT-TURN-003
  it "does not stall a turn with a pending confirmation" do
    session = create(:chat_session)
    message = create(:chat_message, chat_session: session)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")
    turn = create(:chat_turn, chat_session: session, initiating_message: message, status: "streaming", last_activity_at: 11.minutes.ago)

    described_class.new.perform

    expect(turn.reload.status).to eq("streaming")
  end

  # @spec CHAT-TURN-003
  it "does not stall a turn during a known rate-limit recovery window" do
    session = create(:chat_session, rate_limited_until: 1.hour.from_now)
    message = create(:chat_message, chat_session: session)
    turn = create(:chat_turn, chat_session: session, initiating_message: message, status: "streaming", last_activity_at: 11.minutes.ago)

    described_class.new.perform

    expect(turn.reload.status).to eq("streaming")
  end
end
