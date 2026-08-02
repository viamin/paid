# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::HandleCapabilityTransition do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user, container_capability: "pending") }

  it "publishes tools/list_changed for MCP subscribers when capability changes" do
    subscriber = Mcp::SessionTransport.subscribe(session_id: chat_session.id)

    described_class.call(chat_session:, from: "pending", to: "ready")

    event = subscriber.pop(timeout: 1)

    expect(event).to eq(
      event: "message",
      data: {
        jsonrpc: "2.0",
        method: "notifications/tools/list_changed",
        params: {
          sessionId: chat_session.external_id,
          containerCapability: "ready",
          previousContainerCapability: "pending"
        }
      }
    )
  ensure
    Mcp::SessionTransport.unsubscribe(session_id: chat_session.id, subscriber:)
  end

  it "persists a degraded-capability system notice" do
    described_class.call(chat_session:, from: "ready", to: "failed")

    notice = chat_session.messages.where(role: "system").find_by("metadata ->> 'container_capability_notice' = 'true'")

    expect(notice.content).to eq(Containers::CapabilityMessages.notice_for("failed"))
    expect(notice.metadata).to include(
      "container_capability_notice" => true,
      "container_capability" => "failed"
    )
  end

  it "does not persist a stopped notice for intentionally closed sessions" do
    chat_session.update!(status: "closed")

    expect {
      described_class.call(chat_session:, from: "ready", to: "stopped")
    }.not_to change { chat_session.messages.container_capability_notices.count }
  end

  it "does not persist a stopped notice for intentionally archived sessions" do
    chat_session.update!(status: "archived")

    expect {
      described_class.call(chat_session:, from: "ready", to: "stopped")
    }.not_to change { chat_session.messages.container_capability_notices.count }
  end
end
