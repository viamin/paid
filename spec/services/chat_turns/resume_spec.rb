# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Resume do
  # @spec CHAT-TURN-004
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:turn) { create(:chat_turn, chat_session: session, status: "stalled") }

  it "queues one checkpoint recovery and prevents repeated recovery" do
    expect { described_class.call(turn:, actor: user) }
      .to have_enqueued_job(ChatSessions::ProcessMessageJob)
      .with(hash_including(chat_session_id: session.id, content: turn.user_message.content))

    expect(turn.reload).to have_attributes(status: "streaming", recovery_attempts: 1)
    expect { described_class.call(turn:, actor: user) }
      .to raise_error(ChatTurns::Resume::UnsafeRecoveryError)
    expect(turn.reload.duplicate_prevention_count).to eq(1)
  end

  it "refuses recovery after an approved tool call completed" do
    tool_call = create(:chat_message, chat_session: session, role: "assistant", content: nil,
      tool_name: "trigger_agent_run", tool_call_id: "write-1", tool_status: "approved")
    create(:chat_message, :tool, chat_session: session, tool_call_id: tool_call.tool_call_id)

    expect { described_class.call(turn:, actor: user) }.to raise_error(ChatTurns::Resume::UnsafeRecoveryError)
    expect(turn.reload.status).to eq("stalled")
  end
end
