# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-API-027
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:now) { Time.zone.parse("2026-10-28 07:00:00 UTC") }

  it "marks an incomplete inactive turn stalled and persists an actionable transcript notice" do
    user_message = create(:chat_message, chat_session:, role: "user", created_at: now - 1.hour)
    turn = create(:chat_turn, chat_session:, user_message:, last_activity_at: now - 31.minutes)

    expect {
      described_class.call(now:, timeout: 30.minutes)
    }.to change { chat_session.messages.where(role: "system").count }.by(1)

    expect(turn.reload).to have_attributes(state: "stalled", detected_stalled_at: now,
      failure_classification: "missing_durable_activity")
    notice = chat_session.messages.order(:id).last
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("remaining work is unknown")
    expect(notice.metadata).to include("chat_turn_id" => turn.id, "user_message_id" => user_message.id)
  end

  it "does not stall a pending confirmation and records it as a completed pause" do
    user_message = create(:chat_message, chat_session:, role: "user", created_at: now - 1.hour)
    turn = create(:chat_turn, chat_session:, user_message:, last_activity_at: now - 31.minutes)
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending", created_at: now - 30.minutes)

    expect {
      described_class.call(now:, timeout: 30.minutes)
    }.not_to change { chat_session.messages.where(role: "system").count }

    expect(turn.reload.state).to eq("completed")
    expect(turn.metadata).to include("completion_reason" => "awaiting_confirmation")
  end

  it "does not duplicate the notice when repeated detectors race" do
    turn = create(:chat_turn, chat_session:, last_activity_at: now - 31.minutes)

    2.times { described_class.call(now:, timeout: 30.minutes) }

    expect(turn.reload.state).to eq("stalled")
    expect(chat_session.messages.where("metadata ->> 'chat_turn_id' = ?", turn.id.to_s).count).to eq(1)
  end
end
