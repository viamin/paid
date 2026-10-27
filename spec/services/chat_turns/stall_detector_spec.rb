# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::StallDetector do
  # @spec CHAT-TURN-001 CHAT-TURN-002
  let(:chat_session) { create(:chat_session) }

  it "marks an inactive streaming turn stalled and persists an explanatory transcript notice" do
    turn = create(:chat_turn, chat_session:, activity_at: 11.minutes.ago)

    expect {
      described_class.call(now: Time.current)
    }.to change { chat_session.messages.where(role: "system").count }.by(1)

    expect(turn.reload).to have_attributes(status: "stalled", failure_classification: "no_durable_activity")
    notice = chat_session.messages.order(:id).last
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("stopped without a final assistant response")
  end

  it "does not stall a turn waiting for a confirmation" do
    turn = create(:chat_turn, chat_session:, status: "awaiting_confirmation", activity_at: 1.hour.ago)

    expect { described_class.call(now: Time.current) }.not_to change(ChatMessage, :count)
    expect(turn.reload.status).to eq("awaiting_confirmation")
  end

  it "does not create duplicate notices when sweeps overlap" do
    turn = create(:chat_turn, chat_session:, activity_at: 11.minutes.ago)

    2.times { described_class.call(now: Time.current) }

    expect(turn.reload.status).to eq("stalled")
    expect(chat_session.messages.where("metadata ->> 'stalled_turn_notice' = 'true'")).to have_attributes(count: 1)
  end
end
