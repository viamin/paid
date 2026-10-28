# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Retry do
  # @spec CHAT-TURN-002
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:session) { create(:chat_session, account:, created_by: actor) }
  let(:user_message) { create(:chat_message, chat_session: session) }

  it "queues one retry for a stalled turn with no tool activity" do
    turn = create(:chat_turn, chat_session: session, actor:, user_message:, status: "stalled", stream_message_id: SecureRandom.uuid)

    expect { described_class.call(chat_turn: turn, actor:) }
      .to have_enqueued_job(ChatSessions::ProcessMessageJob)

    expect(turn.reload.status).to eq("streaming")
    expect(turn.recovery_attempts).to eq(1)
  end

  it "refuses a retry when a tool was persisted after the user message" do
    turn = create(:chat_turn, chat_session: session, actor:, user_message:, status: "stalled")
    create(:chat_message, :tool, chat_session: session)

    expect { described_class.call(chat_turn: turn, actor:) }
      .to raise_error(described_class::UnsafeRecoveryError)
  end
end
