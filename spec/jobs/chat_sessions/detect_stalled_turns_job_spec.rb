# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::DetectStalledTurnsJob, type: :job do
  # @spec CHAT-API-027
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  def create_active_turn(status: "streaming", activity_at: 11.minutes.ago)
    message = create(:chat_message, chat_session:, role: "user", content: "Do the thing", metadata: {
      "stream_message_id" => SecureRandom.uuid,
      "turn" => { "status" => status, "last_activity_at" => activity_at.iso8601 }
    })
    message
  end

  it "marks an inactive turn stalled and preserves a visible durable notice" do
    message = create_active_turn

    described_class.perform_now(now: Time.current)

    expect(message.reload.metadata.dig("turn", "status")).to eq("stalled")
    notice = chat_session.messages.find_by("metadata ->> 'stalled_turn_message_id' = ?", message.id.to_s)
    expect(notice).to be_stalled_turn_notice
    expect(notice.content).to include("before Paid recorded a final answer")
  end

  it "does not stall a turn awaiting confirmation" do
    message = create_active_turn
    create(:chat_message, :tool_call, chat_session:, tool_status: "pending")

    described_class.perform_now(now: Time.current)

    expect(message.reload.metadata.dig("turn", "status")).to eq("streaming")
    expect(chat_session.messages.where("metadata ->> 'stalled_turn_notice' = 'true'")).not_to exist
  end

  it "does not stall a known rate-limited session" do
    message = create_active_turn
    chat_session.update!(rate_limited_until: 1.hour.from_now)

    described_class.perform_now(now: Time.current)

    expect(message.reload.metadata.dig("turn", "status")).to eq("streaming")
  end

  it "does not duplicate a notice when concurrent sweeps observe the same turn" do
    create_active_turn

    2.times { described_class.perform_now(now: Time.current) }

    expect(chat_session.messages.where("metadata ->> 'stalled_turn_notice' = 'true'").count).to eq(1)
  end
end
