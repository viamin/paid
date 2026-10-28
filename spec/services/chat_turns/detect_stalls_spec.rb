# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalls do
  describe ".call" do
    it "marks an inactive unfinished turn stalled and preserves a transcript notice" do # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-003
      session = create(:chat_session)
      user_message = create(:chat_message, chat_session: session, role: "user", content: "Continue")
      checkpoint = create(:chat_message, :tool_call, chat_session: session)
      turn = ChatTurn.create!(chat_session: session, user_message:, checkpoint_message: checkpoint,
        status: "streaming", last_activity_at: 11.minutes.ago)

      described_class.call

      expect(turn.reload).to have_attributes(status: "stalled", stalled_at: be_present)
      notice = session.messages.last
      expect(notice).to be_chat_turn_stalled_notice
      expect(notice.metadata).to include("chat_turn_id" => turn.id, "checkpoint_message_id" => checkpoint.id)
    end

    it "does not stall a turn that is awaiting explicit confirmation" do # @spec CHAT-TURN-RECOVERY-002
      session = create(:chat_session)
      ChatTurn.create!(chat_session: session, status: "streaming", last_activity_at: 11.minutes.ago)
      create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

      described_class.call

      expect(ChatTurn.last.status).to eq("streaming")
    end

    it "does not stall a turn while its session is rate limited" do # @spec CHAT-TURN-RECOVERY-002
      session = create(:chat_session, rate_limited_until: 1.minute.from_now)
      turn = ChatTurn.create!(chat_session: session, status: "streaming", last_activity_at: 11.minutes.ago)

      described_class.call

      expect(turn.reload.status).to eq("streaming")
    end
  end
end
