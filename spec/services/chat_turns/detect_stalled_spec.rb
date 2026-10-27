# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::DetectStalled do
  # @spec CHAT-API-027
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:now) { Time.zone.parse("2026-10-27 19:00:00") }

  it "marks a turn with partial durable activity as stalled and preserves an actionable notice" do
    turn = create(:chat_turn, chat_session:, actor: user, last_activity_at: 11.minutes.before(now))
    create(:chat_message, chat_session:, chat_turn: turn, role: "user", content: "Deploy this")
    create(:chat_message, :tool, chat_session:, chat_turn: turn, tool_name: "list_projects")

    expect { described_class.call(now:) }.to change { chat_session.messages.system.count }.by(1)

    notice = chat_session.messages.system.last
    expect(turn.reload).to have_attributes(status: "stalled", stall_classification: "no_durable_activity")
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("final assistant response is unknown")
    expect(notice.metadata).to include("chat_turn_id" => turn.id)
  end

  it "does not mark a turn waiting for user confirmation as stalled" do
    turn = create(:chat_turn, chat_session:, actor: user, last_activity_at: 11.minutes.before(now))
    create(:chat_message, :tool_call, chat_session:, chat_turn: turn, tool_status: "pending")

    expect(described_class.call(now:)).to be_empty
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not mark a known rate-limited session as stalled" do
    chat_session.update!(rate_limited_until: 5.minutes.from_now)
    turn = create(:chat_turn, chat_session:, actor: user, last_activity_at: 11.minutes.before(now))

    expect(described_class.call(now:)).to be_empty
    expect(turn.reload.status).to eq("streaming")
  end

  it "does not create duplicate notices when sweeps overlap" do
    turn = create(:chat_turn, chat_session:, actor: user, last_activity_at: 11.minutes.before(now))

    2.times { described_class.call(now:) }

    expect(turn.reload.status).to eq("stalled")
    expect(chat_session.messages.where("metadata ->> 'stalled_turn_notice' = 'true'").count).to eq(1)
  end
end
