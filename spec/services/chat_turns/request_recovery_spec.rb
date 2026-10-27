# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::RequestRecovery do
  # @spec CHAT-TURN-RECOVERY-004
  let(:session) { create(:chat_session) }
  let(:actor) { session.created_by }
  let(:turn) { create(:chat_turn, chat_session: session, status: "stalled", last_activity_at: 11.minutes.ago) }

  it "claims recovery once and records duplicate prevention" do
    described_class.call(turn:, actor:)

    expect(turn.reload).to have_attributes(status: "streaming", recovery_attempts: 1)
    expect { described_class.call(turn:, actor:) }
      .to raise_error(described_class::ConflictError)
    expect(turn.events.last.event_type).to eq("recovery_duplicate")
  end
end
