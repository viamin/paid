# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-TURN-RECOVERY-001
  it "records a terminal completion instead of treating it as an active turn" do
    turn = create(:chat_turn)

    turn.complete!

    expect(turn).to have_attributes(state: "completed", completed_at: be_present)
    expect(described_class.active).not_to include(turn)
  end
end
