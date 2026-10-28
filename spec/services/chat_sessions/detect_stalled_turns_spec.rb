# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurns do
  # @spec CHAT-API-026
  it "marks an inactive streaming turn stalled and preserves a visible recovery notice" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session)
    turn = create(:chat_turn, chat_session: session, user_message:, status: "streaming", last_activity_at: 16.minutes.ago)

    described_class.call(now: Time.current)

    expect(turn.reload).to have_attributes(status: "stalled", failure_classification: "unknown")
    expect(session.messages.last).to have_attributes(role: "system")
    expect(session.messages.last.metadata).to include("stalled_turn_notice" => true, "chat_turn_id" => turn.id)
  end

  # @spec CHAT-API-026
  it "does not stall a turn that is awaiting explicit tool confirmation" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session)
    create(:chat_turn, chat_session: session, user_message:, status: "awaiting_confirmation", last_activity_at: 1.hour.ago)

    expect { described_class.call(now: Time.current) }.not_to change(ChatMessage, :count)
  end
end
