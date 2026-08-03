# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Chat background provisioning", type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user, container_capability: "pending") }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  it "renders the assistant response and the ready capability after background provisioning completes" do
    visit_chat_session

    create(:chat_message, chat_session:, role: "user", content: "Hello")
    create(:chat_message, :assistant, chat_session:, content: "Inline response", model: "gpt-4o")
    chat_session.update!(container_capability: "ready")
    visit_chat_session

    expect(page).to have_text("Inline response")
    expect(page).to have_css("span[data-capability='ready']", text: "Ready")
  end

  it "shows the provisioning failure notice while chat remains usable inline" do
    visit_chat_session

    chat_session.update!(container_capability: "failed")
    create(:chat_message, :system, chat_session:,
      content: Containers::CapabilityMessages.notice_for("failed"),
      metadata: { "container_capability_notice" => true, "container_capability" => "failed" })

    create(:chat_message, chat_session:, role: "user", content: "Can you still help?")
    create(:chat_message, :assistant, chat_session:, content: "Inline tools still work", model: "gpt-4o")
    visit_chat_session

    expect(page).to have_css("span[data-capability='failed']", text: "Failed")
    expect(page).to have_text("Workspace tools are currently unavailable")
    expect(page).to have_text("Inline tools still work")
  end

  def visit_chat_session
    visit chat_session_path(chat_session, format: :html)
    expect(page).to have_css("div[data-controller='chat']", wait: 10)
    expect(page).to have_text(chat_session.container_capability.titleize)
  end
end
