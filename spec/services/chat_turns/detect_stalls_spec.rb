# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalls do
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-004
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  it "marks an inactive streaming turn stalled and preserves a visible notice" do
    turn = create(:chat_turn, chat_session:, activity_at: 11.minutes.ago)

    described_class.call

    expect(turn.reload).to have_attributes(status: "stalled", classification: "no_durable_activity")
    notice = chat_session.messages.find_by(metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "user_message_id" => turn.user_message_id })
    expect(notice.content).to include("stopped without a final response")
  end

  it "does not stall a turn awaiting confirmation" do
    turn = create(:chat_turn, chat_session:, activity_at: 11.minutes.ago, metadata: { "awaiting_confirmation" => true })

    described_class.call

    expect(turn.reload.status).to eq("streaming")
  end

  it "does not stall a rate-limited session" do
    chat_session.update!(rate_limited_until: 1.minute.from_now)
    turn = create(:chat_turn, chat_session:, activity_at: 11.minutes.ago)

    described_class.call

    expect(turn.reload.status).to eq("streaming")
  end
end
