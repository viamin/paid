# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-001 CHAT-TURN-002
  let(:turn) { create(:chat_turn) }

  it "starts pending and records durable activity while streaming" do
    expect(turn.status).to eq("pending")

    turn.start!

    expect(turn.reload.status).to eq("streaming")
    expect(turn.activity_at).to be_present
  end

  it "does not consider a pending tool confirmation stalled" do
    create(:chat_message, :tool_call, chat_session: turn.chat_session, tool_status: "pending")
    turn.start!

    expect(turn.reload.stallable?).to be(false)
  end
end
