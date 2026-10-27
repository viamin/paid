# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  let(:session) { create(:chat_session) }
  let(:now) { Time.current }

  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  it "marks an inactive streaming turn stalled once and preserves a recovery notice" do
    user_message = create(:chat_message, chat_session: session, created_at: 20.minutes.ago)
    turn = ChatTurn.create!(chat_session: session, user_message:, stream_message_id: SecureRandom.uuid,
      status: "streaming", activity_at: 20.minutes.ago)

    described_class.call(now:, threshold: 10.minutes)

    expect(turn.reload).to have_attributes(status: "stalled", stalled_at: be_present)
    notice = session.messages.find_by(metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id,
      "side_effecting_tools_completed" => false })
    expect(notice.content).to include("will not automatically replay tools")

    described_class.call(now: now + 1.minute, threshold: 10.minutes)
    expect(session.messages.where("metadata ->> 'stalled_turn_notice' = 'true'").count).to eq(1)
  end

  # @spec CHAT-TURN-RECOVERY-002
  it "does not stall a turn waiting for a confirmation" do
    user_message = create(:chat_message, chat_session: session, created_at: 20.minutes.ago)
    ChatTurn.create!(chat_session: session, user_message:, stream_message_id: SecureRandom.uuid,
      status: "streaming", activity_at: 20.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending", created_at: 19.minutes.ago)

    described_class.call(now:, threshold: 10.minutes)

    expect(session.chat_turns.last.status).to eq("streaming")
  end
end
