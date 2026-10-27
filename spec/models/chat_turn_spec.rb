# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurn do
  # @spec CHAT-API-027
  it "only considers active, unanswered turns stale" do
    session = create(:chat_session)
    user_message = create(:chat_message, chat_session: session)
    stale = described_class.create!(chat_session: session, user_message:, state: "streaming", activity_at: 11.minutes.ago)
    confirmation = described_class.create!(chat_session: session, user_message: create(:chat_message, chat_session: session), state: "awaiting_confirmation", activity_at: 11.minutes.ago)

    expect(described_class.stale).to include(stale)
    expect(described_class.stale).not_to include(confirmation)
  end
end
