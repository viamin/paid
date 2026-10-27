# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-RECOVERY-003
  it "records durable lifecycle events" do
    turn = create(:chat_turn, status: "pending")

    turn.start!
    turn.complete!

    expect(turn).to have_attributes(status: "completed", completed_at: be_present)
    expect(turn.events.pluck(:event_type)).to include("started", "completed")
  end
end
