# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob, type: :job do
  # @spec CHAT-API-027
  it "runs the detector for active turns" do
    turn = create(:chat_turn, :streaming)
    allow(ChatSessions::DetectStalledTurns).to receive(:call)

    described_class.perform_now

    expect(ChatSessions::DetectStalledTurns).to have_received(:call).with(turn:)
  end
end
