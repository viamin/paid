# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-API-027
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session:, role: "user", content: "Investigate this") }

  it "allows only one recovery claim for a stalled revision" do
    turn = described_class.create!(chat_session:, user_message:, actor: user, status: "stalled", last_activity_at: 10.minutes.ago)

    expect(turn.claim_recovery!(actor: user, expected_lock_version: turn.lock_version)).to be(true)
    expect(turn.reload.claim_recovery!(actor: user, expected_lock_version: turn.lock_version)).to be(false)
    expect(turn.events.pluck(:event_type)).to include("recovery_requested", "recovery_duplicate_prevented")
  end
end
