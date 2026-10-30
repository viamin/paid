# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ExpireIdleInline do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  # @spec CHAT-API-028
  it "does not expire a chat whose timeout was extended after the reaper selected it" do
    session = create(:chat_session, account: account, created_by: user, idle_timeout_at: 1.minute.ago)
    session.update!(idle_timeout_at: 30.minutes.from_now)

    described_class.call(chat_session: session)

    expect(session.reload.status).to eq("active")
  end

  # @spec CHAT-API-028
  it "closes a conversation with user messages and keeps its transcript" do
    session = create(:chat_session, account: account, created_by: user, idle_timeout_at: 1.minute.ago)
    create(:chat_message, chat_session: session, role: "user")

    described_class.call(chat_session: session)

    expect(session.reload.status).to eq("closed")
    expect(session.messages.where(role: "user").count).to eq(1)
  end
end
