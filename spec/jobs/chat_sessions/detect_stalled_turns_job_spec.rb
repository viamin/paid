# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob do
  # @spec CHAT-TURN-001
  it "delegates stale-turn detection" do
    expect(ChatTurns::DetectStalls).to receive(:call)

    described_class.new.perform
  end
end
