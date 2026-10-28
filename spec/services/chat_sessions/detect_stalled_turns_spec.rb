# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-API-027
  it "marks an inactive streaming turn stalled and preserves an actionable transcript notice" do
    turn = create(:chat_turn, last_activity_at: 11.minutes.ago)

    expect { described_class.call }
      .to change { turn.reload.lifecycle }.from("streaming").to("stalled")
      .and change { turn.chat_session.messages.count }.by(1)

    notice = turn.chat_session.messages.last
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("stopped without a final response")
    expect(notice.metadata).to include("chat_turn_id" => turn.id, "classification" => "inactivity_timeout")
  end

  it "does not classify a pending confirmation as stalled" do
    turn = create(:chat_turn, lifecycle: "awaiting_confirmation", last_activity_at: 1.hour.ago)

    expect { described_class.call }.not_to change { turn.reload.lifecycle }
  end

  it "does not classify a turn with recent durable activity as stalled" do
    turn = create(:chat_turn, last_activity_at: 9.minutes.ago)

    expect { described_class.call }.not_to change { turn.reload.lifecycle }
  end

  it "uses the supplied inactivity threshold" do
    turn = create(:chat_turn, last_activity_at: 2.minutes.ago)

    described_class.call(inactivity_threshold: 1.minute)

    expect(turn.reload.lifecycle).to eq("stalled")
  end
end
