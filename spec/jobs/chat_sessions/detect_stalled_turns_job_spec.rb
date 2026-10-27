# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob do
  # @spec CHAT-TURN-001
  it "runs detection under system access" do
    allow(ChatSessions::DetectStalledTurns).to receive(:call).and_return(0)

    described_class.new.perform

    expect(ChatSessions::DetectStalledTurns).to have_received(:call)
  end
end
