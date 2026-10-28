# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-007
  it "exposes terminal and recoverable lifecycle states" do
    turn = build(:chat_turn, state: "stalled", detected_stalled_at: Time.current)

    expect(turn).to be_stalled
    expect(described_class.states).to include("completed", "failed", "abandoned")
  end

  # @spec CHAT-TURN-RECOVERY-005
  it "only permits bounded automatic recovery for replay-safe infrastructure failures" do
    safe = build(:chat_turn, state: "failed", failure_classification: "infrastructure", recovery_attempts_count: 0)
    unsafe = build(:chat_turn, state: "failed", failure_classification: "infrastructure", side_effects_completed: true)

    expect(safe).to be_automatic_recovery_safe
    expect(unsafe).not_to be_automatic_recovery_safe
  end
end
