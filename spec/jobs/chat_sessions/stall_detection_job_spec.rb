# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::StallDetectionJob, type: :job do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  it "stalls stale incomplete turns and persists a warning notice" do
    # @spec CHAT-TURN-STALL-001
    turn = create(:chat_turn, :streaming, chat_session: chat_session, last_activity_at: 20.minutes.ago)

    described_class.perform_now(now: Time.current)

    expect(turn.reload.status).to eq("stalled")
    expect(chat_session.messages.reload.last).to have_attributes(role: "system")
    expect(chat_session.messages.last.stalled_turn_notice?).to be(true)
  end

  it "does not stall turns with pending confirmation" do
    # @spec CHAT-TURN-STALL-002
    turn = create(:chat_turn, :streaming, chat_session: chat_session, last_activity_at: 20.minutes.ago)
    create(:chat_message, :tool_call, chat_session: chat_session, tool_status: "pending")

    described_class.perform_now(now: Time.current)

    expect(turn.reload.status).to eq("streaming")
  end

  it "does not stall an explicitly marked long-running operation" do
    # @spec CHAT-TURN-STALL-002
    turn = create(:chat_turn, :streaming, chat_session: chat_session,
      last_activity_at: 20.minutes.ago, metadata: { "long_running_operation" => true })

    described_class.perform_now(now: Time.current)

    expect(turn.reload.status).to eq("streaming")
  end

  it "does not create duplicate notices on repeated detection" do
    # @spec CHAT-TURN-STALL-003
    turn = create(:chat_turn, :streaming, chat_session: chat_session, last_activity_at: 20.minutes.ago)

    described_class.perform_now(now: Time.current)
    described_class.perform_now(now: Time.current)

    expect(chat_session.messages.where(metadata: { "stalled_turn_notice" => true }).count).to eq(1)
  end
end
