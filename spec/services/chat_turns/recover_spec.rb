# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Recover do
  # @spec CHAT-API-026
  let(:chat_session) { create(:chat_session) }
  let(:actor) { chat_session.created_by }

  it "queues one explicit retry from the original turn when no tool result was saved" do
    turn = create(:chat_turn, chat_session:, state: "stalled")

    expect {
      described_class.call(turn:, actor:)
    }.to have_enqueued_job(ChatSessions::ProcessMessageJob).with(
      chat_session_id: chat_session.id, actor_id: actor.id,
      content: turn.user_message.content, stream_message_id: turn.stream_message_id
    )

    expect(turn.reload).to have_attributes(state: "pending", recovery_attempts: 1)
  end

  it "refuses a replay after saved tool activity" do
    turn = create(:chat_turn, chat_session:, state: "stalled")
    create(:chat_message, :tool, chat_session:, tool_call_id: "saved-result")

    expect { described_class.call(turn:, actor:) }.to raise_error(ChatTurns::Recover::UnsafeReplayError)
    expect(turn.reload).to be_stalled
  end
end
