# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Chat background provisioning", type: :system do
  include ActiveJob::TestHelper
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:chat_session) { ChatSessions::Create.call(account:, user:, container_capability: "pending") }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    clear_enqueued_jobs
    clear_performed_jobs
    Warden.test_reset!
  end

  it "renders the assistant response and the ready capability after background provisioning completes" do
    allow(Containers::ProvisionForChat).to receive(:call) do |chat_session:|
      chat_session.update!(
        container_capability: "ready",
        container_id: "chat-container-1",
        container_ready_at: Time.current
      )
      Containers::Provision::Result.success(container_id: "chat-container-1")
    end
    create(:chat_message, chat_session:, role: "user", content: "Hello")
    create(:chat_message, :assistant, chat_session:, content: "Inline response", model: "gpt-4o")

    visit_chat_session

    expect {
      perform_enqueued_jobs(only: ChatSessions::ProvisionContainerJob)
    }.to have_broadcasted_to("chat_session:#{chat_session.id}")
      .with(hash_including(type: "capability_changed", container_capability: "ready"))

    expect(page).to have_text("Inline response")
    expect(chat_session.reload.container_capability).to eq("ready")
  end

  it "shows the provisioning failure notice while chat remains usable inline" do
    allow(Containers::ProvisionForChat).to receive(:call) do |chat_session:|
      chat_session.update!(container_capability: "failed")
      raise Containers::ProvisionForChat::ProvisionError, "Docker error: image pull failed"
    end
    create(:chat_message, chat_session:, role: "user", content: "Can you still help?")
    create(:chat_message, :assistant, chat_session:, content: "Inline tools still work", model: "gpt-4o")

    visit_chat_session

    # The test Action Cable adapter captures broadcasts but does not push them
    # into rack_test's DOM, so this system example verifies the open-page path
    # by running the real job and asserting the exact broadcasts the browser
    # depends on, without reloading the page.
    perform_enqueued_jobs(only: ChatSessions::ProvisionContainerJob)

    broadcasts = ActionCable.server.pubsub.broadcasts("chat_session:#{chat_session.id}").map { |payload| JSON.parse(payload) }
    expect(broadcasts).to include(hash_including("type" => "capability_changed", "container_capability" => "failed"))
    expect(broadcasts).to include(hash_including("type" => "message_created"))

    expect(page).to have_text("Inline tools still work")
    expect(chat_session.reload.container_capability).to eq("failed")
    expect(chat_session.messages.container_capability_notices.first&.content)
      .to eq(Containers::CapabilityMessages.notice_for("failed"))
  end

  def visit_chat_session
    visit chat_session_path(chat_session, format: :html)
    expect(page).to have_css("div[data-controller='chat']", wait: 10)
    expect(page).to have_text(chat_session.container_capability.titleize)
  end
end
