# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::Turns::Recover do
  # @spec CHAT-TURN-RECOVERY-006 CHAT-TURN-RECOVERY-008 CHAT-TURN-RECOVERY-009
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:message) { create(:chat_message, chat_session: session) }
  let(:turn) do
    ChatTurn.create!(chat_session: session, user_message: message, status: "stalled", started_at: 10.minutes.ago,
      last_activity_at: 6.minutes.ago, stalled_at: 1.minute.ago, finished_at: 1.minute.ago)
  end

  it "requires confirmation for an ambiguous stalled turn" do
    expect {
      described_class.call(turn:, actor: user, revision: turn.revision)
    }.to raise_error(described_class::ConfirmationRequired)
  end

  it "claims a confirmed recovery once and records an audit event" do
    expect {
      described_class.call(turn:, actor: user, revision: turn.revision, confirmed: true)
    }.to have_enqueued_job(ChatSessions::RecoverStalledTurnJob)

    expect(turn.reload.recovery_state).to eq("in_progress")
    expect(turn.events.find_by(event_type: "recovery_requested")).to be_present
  end

  it "rejects a stale revision without enqueuing another recovery" do
    expect {
      described_class.call(turn:, actor: user, revision: turn.revision + 1, confirmed: true)
    }.to raise_error(described_class::Conflict, /out of date/)
  end
end
