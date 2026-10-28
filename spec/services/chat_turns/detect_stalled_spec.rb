# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:now) { Time.zone.parse("2026-10-28 12:00:00") }

  # @spec CHAT-TURN-RECOVERY-004 CHAT-TURN-RECOVERY-007 CHAT-TURN-RECOVERY-013
  it "marks unexplained durable silence stalled and preserves an actionable transcript notice" do
    turn = create_open_turn(last_activity_at: 11.minutes.before(now))

    summary = described_class.call(now:)

    expect(summary.stalled).to eq(1)
    expect(turn.reload).to have_attributes(state: "stalled", classification: "infrastructure_failure")
    notice = chat_session.messages.find(&:stalled_turn_notice?)
    expect(notice.content).to include("stopped without a final answer", "Still unknown")
    expect(notice.metadata).to include("chat_turn_id" => turn.id, "revision" => turn.revision)
    rendered = ApplicationController.render(partial: "chat_messages/message", locals: { message: notice })
    expect(rendered).to include("Turn stalled", "Resume this turn")
    expect(turn.events.classified.last).to have_attributes(outcome: "infrastructure_failure")
  end

  # @spec CHAT-TURN-RECOVERY-005
  it "does not falsely mark a pending confirmation stalled" do
    turn = create_open_turn(last_activity_at: 11.minutes.before(now))
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending", tool_name: "create_issue")
    turn.update!(last_activity_at: 11.minutes.before(now))

    expect(ChatTurns::Classify.call(turn).classification).to eq("pending_confirmation")

    summary = described_class.call(now:)

    expect(summary.waiting).to eq(1)
    expect(turn.reload).to have_attributes(state: "streaming")
    expect(chat_session.messages).not_to be_any(&:stalled_turn_notice?)
  end

  # @spec CHAT-TURN-RECOVERY-006
  it "does not falsely mark a declared long-running tool stalled" do
    turn = create_open_turn(last_activity_at: 11.minutes.before(now))
    create(:chat_message, :tool_call, chat_session:, tool_name: "run_shell")
    turn.update!(last_activity_at: 11.minutes.before(now))

    expect(ChatTurns::Classify.call(turn).classification).to eq("long_running_operation")

    described_class.call(now:)

    expect(turn.reload.state).to eq("streaming")
    expect(turn.events.classified.last.outcome).to eq("long_running_operation")
  end

  private

  def create_open_turn(last_activity_at:)
    user_message = create(:chat_message, chat_session:, created_at: 12.minutes.before(now))
    create(:chat_turn, chat_session:, user_message:, state: "streaming", last_activity_at:)
  end
end
