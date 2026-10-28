# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob, type: :job do
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  it "persists a stalled outcome and notice only once" do
    turn = create(:chat_turn, :streaming, last_activity_at: 10.minutes.ago)

    described_class.perform_now(now: Time.current)
    described_class.perform_now(now: Time.current)

    expect(turn.reload).to have_attributes(status: "stalled", detected_stalled_at: be_present)
    expect(turn.chat_session.messages.where("metadata ->> 'chat_turn_stalled_notice' = 'true'").count).to eq(1)
  end

  it "does not stall a known rate-limited operation" do
    turn = create(:chat_turn, :streaming, last_activity_at: 10.minutes.ago)
    turn.chat_session.update!(rate_limited_until: 2.minutes.from_now)

    described_class.perform_now(now: Time.current)

    expect(turn.reload.status).to eq("streaming")
  end
end
