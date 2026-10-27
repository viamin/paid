# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-004
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:user_message) { create(:chat_message, chat_session:) }

  it "marks an inactive streaming turn stalled and records one durable notice" do
    turn = create(:chat_turn, :streaming, chat_session:, user_message:, actor: user,
      last_activity_at: 16.minutes.ago)

    expect {
      described_class.call(now: Time.current)
    }.to change { turn.reload.status }.from("streaming").to("stalled")
      .and change { chat_session.messages.where(role: "system").count }.by(1)

    notice = chat_session.messages.system.last
    expect(notice.metadata).to include("chat_turn_stalled" => true, "chat_turn_id" => turn.id)
    expect(notice.content).to include("No tool calls were durably recorded")
  end

  it "does not stall a turn waiting for confirmation" do
    create(:chat_turn, :awaiting_confirmation, chat_session:, user_message:, actor: user,
      last_activity_at: 16.minutes.ago)

    expect { described_class.call(now: Time.current) }
      .not_to change { ChatTurn.where(status: "stalled").count }
  end

  it "does not stall a turn with recent durable activity" do
    create(:chat_turn, :streaming, chat_session:, user_message:, actor: user,
      last_activity_at: 2.minutes.ago)

    expect { described_class.call(now: Time.current) }
      .not_to change { ChatTurn.where(status: "stalled").count }
  end

  it "queues only one safe recovery when no tool activity was recorded" do
    turn = create(:chat_turn, :streaming, chat_session:, user_message:, actor: user,
      last_activity_at: 16.minutes.ago)

    expect {
      described_class.call(now: Time.current)
    }.to have_enqueued_job(ChatSessions::RecoverStalledTurnJob).with(chat_turn_id: turn.id)

    expect { described_class.call(now: Time.current) }
      .not_to have_enqueued_job(ChatSessions::RecoverStalledTurnJob)
  end

  it "does not auto-recover a turn after a durable tool request" do
    turn = create(:chat_turn, :streaming, chat_session:, user_message:, actor: user,
      last_activity_at: 16.minutes.ago)
    create(:chat_message, chat_session:, role: "assistant", content: nil,
      tool_name: "create_issue", tool_call_id: "call_1")

    expect { described_class.call(now: Time.current) }
      .not_to have_enqueued_job(ChatSessions::RecoverStalledTurnJob)
    expect(turn.reload.metadata).to include("auto_recovery_eligible" => false)
  end
end
