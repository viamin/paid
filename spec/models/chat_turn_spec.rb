# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-001
  it "records durable lifecycle transitions and events" do
    turn = create(:chat_turn)

    turn.start!
    turn.complete!

    expect(turn.reload).to have_attributes(status: "completed", terminal_at: be_present)
    expect(turn.events.pluck(:event_type)).to include("started", "completed")
  end

  it "does not transition a terminal turn again" do
    turn = create(:chat_turn, status: "completed", terminal_at: Time.current)

    expect(turn.stall!).to be false
    expect(turn.reload.status).to eq("completed")
  end
end
