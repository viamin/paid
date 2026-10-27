# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec API-CONVERSATION-DELEGATION-008
  describe ".call" do
    it "marks an inactive streaming turn stalled and preserves an actionable transcript notice" do
      turn = create(:chat_turn, last_activity_at: 11.minutes.ago)

      expect { described_class.call }.to change { turn.reload.status }.from("streaming").to("stalled")

      notice = turn.chat_session.messages.last
      expect(notice).to be_stalled_turn_notice
      expect(notice.content).to include("No tool has been replayed")
      expect(notice.metadata).to include("chat_turn_id" => turn.id)
    end

    it "does not classify a turn waiting on a confirmation" do
      turn = create(:chat_turn, status: "waiting_confirmation", last_activity_at: 1.hour.ago)
      create(:chat_message, :tool_call, chat_session: turn.chat_session, tool_status: "pending")

      expect { described_class.call }.not_to change { turn.reload.status }
    end

    it "does not classify a known rate-limit pause" do
      turn = create(:chat_turn, last_activity_at: 1.hour.ago, chat_session: create(:chat_session, rate_limited_until: 1.hour.from_now))

      expect { described_class.call }.not_to change { turn.reload.status }
    end

    it "does not duplicate notices when the sweep runs again" do
      turn = create(:chat_turn, last_activity_at: 1.hour.ago)

      described_class.call

      expect { described_class.call }.not_to change { turn.chat_session.messages.stalled_turn_notices.count }
    end
  end
end
