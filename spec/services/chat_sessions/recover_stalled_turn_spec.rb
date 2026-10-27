# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::RecoverStalledTurn do
  # @spec CHAT-TURN-RECOVERY-003
  let(:chat_session) { create(:chat_session) }
  let(:user_message) { create(:chat_message, chat_session:, role: "user") }

  it "claims recovery once and re-enqueues the original checkpoint" do
    turn = create(:chat_turn, chat_session:, user_message:, status: "stalled", activity_at: 20.minutes.ago)

    expect { described_class.call(turn:) }.to have_enqueued_job(ChatSessions::ProcessMessageJob)
      .with(chat_session_id: chat_session.id, content: user_message.content, stream_message_id: turn.stream_message_id)

    expect(turn.reload).to be_pending
    expect(turn.recovery_attempts).to eq(1)
    expect { described_class.call(turn:) }.to raise_error(ChatSessions::RecoverStalledTurn::RecoveryConflictError)
  end

  it "refuses to replay a turn after a completed write tool" do
    turn = create(:chat_turn, chat_session:, user_message:, status: "stalled")
    create(:chat_message, :tool, chat_session:, tool_name: "create_issue", tool_result: { "status" => "ok" })
    allow(Tools::Registry).to receive(:write_tool?).with("create_issue").and_return(true)

    expect { described_class.call(turn:) }.to raise_error(ChatSessions::RecoverStalledTurn::UnsafeRecoveryError)
    expect(turn.reload).to be_stalled
  end
end
