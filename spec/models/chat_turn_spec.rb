# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-001 CHAT-TURN-002
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:session) { create(:chat_session, account:, created_by: actor) }
  let(:user_message) { create(:chat_message, chat_session: session) }

  it "has a durable lifecycle" do
    turn = described_class.create!(chat_session: session, actor:, user_message:, last_activity_at: Time.current)

    turn.start!
    turn.complete!

    expect(turn.status).to eq("completed")
    expect(turn.completed_at).to be_present
  end

  it "does not stall a turn that awaits confirmation" do
    turn = described_class.create!(chat_session: session, actor:, user_message:, status: "streaming", last_activity_at: 11.minutes.ago)
    create(:chat_message, :tool_call, chat_session: session, tool_status: "pending")

    expect(turn.stall!).to be(false)
    expect(turn.reload.status).to eq("streaming")
  end
end
