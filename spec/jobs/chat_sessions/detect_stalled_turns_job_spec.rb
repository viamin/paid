# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob, type: :job do
  # @spec CHAT-TURN-RECOVERY-003
  it "classifies expired active turns without touching recent turns" do
    stale = create(:chat_turn, status: "streaming", last_activity_at: 11.minutes.ago)
    recent = create(:chat_turn, status: "streaming", last_activity_at: 1.minute.ago)

    described_class.perform_now

    expect(stale.reload).to be_stalled
    expect(recent.reload).to be_streaming
  end
end
