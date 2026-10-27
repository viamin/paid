# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalledJob do
  # @spec API-CONVERSATION-DELEGATION-008
  it "runs the durable stall detector" do
    create(:chat_turn, last_activity_at: 11.minutes.ago)

    expect { described_class.perform_now }.to change { ChatTurn.stalled.count }.by(1)
  end
end
