# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-API-027
  let(:chat_session) { create(:chat_session) }
  let(:user_message) { create(:chat_message, chat_session:) }

  it "accepts every durable lifecycle state" do
    described_class::STATUSES.each do |status|
      expect(described_class.new(chat_session:, user_message:, status:, last_activity_at: Time.current)).to be_valid
    end
  end

  it "does not stall a turn that has a pending confirmation" do
    turn = create(:chat_turn, chat_session:, user_message:, status: "streaming", last_activity_at: 20.minutes.ago)
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending")

    expect(turn.stall!).to be(false)
    expect(turn.reload.status).to eq("streaming")
  end
end
