# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob do
  # @spec CHAT-API-028
  it "marks an inactive streaming turn stalled and creates one durable notice" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session)
    turn = create(:chat_turn, chat_session: session, user_message:, status: "streaming", last_activity_at: 20.minutes.ago)

    expect { described_class.new.perform }.to change { session.messages.where("metadata ->> 'stalled_turn_notice' = 'true'").count }.by(1)

    expect(turn.reload).to have_attributes(status: "stalled", stalled_at: be_present, failure_classification: "no_durable_activity")
    expect { described_class.new.perform }.not_to change { session.messages.count }
  end

  # @spec CHAT-API-028
  it "leaves rate-limited and confirmation-paused turns untouched" do
    session = create(:chat_session, rate_limited_until: 1.hour.from_now)
    user_message = create(:chat_message, chat_session: session)
    turn = create(:chat_turn, chat_session: session, user_message:, status: "streaming", last_activity_at: 20.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    expect { described_class.new.perform }.not_to change { session.messages.count }
    expect(turn.reload.status).to eq("streaming")
  end
end
