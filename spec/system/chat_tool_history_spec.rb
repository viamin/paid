# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec CHAT-API-024 CHAT-API-027
RSpec.describe "Bounded tool history in the browser", type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  before do
    driven_by :paid_cuprite
    Warden.test_mode!
    login_as(user, scope: :user)
    insert_tool_history
    page.current_window.resize_to(390, 844)
    visit chat_session_path(chat_session, format: :html)
    find("[data-controller='chat'][style*='--chat-panel-offset-top:']")
    find("[data-chat-tool-group] > summary").execute_script("this.focus()")
    page.driver.browser.keyboard.type(:enter)
  end

  after { Warden.test_reset! }

  it "loads all earlier cards into one disclosure through explicit bounded pages" do
    expect(page).to have_css("[data-chat-tool-card]", count: 50, visible: :all)
    find("[data-chat-tool-history-more]").execute_script("this.focus()")
    page.driver.browser.keyboard.type(:enter)
    expect(page).to have_css("[data-chat-tool-card]", count: 100, visible: :all)
    expect(page).to have_css("[data-chat-tool-group-summary]", text: "100 tool actions shown")
    click_link "Load earlier tool actions"
    expect(page).to have_css("[data-chat-tool-card]", count: 120, visible: :all)
    expect(page).to have_css("[data-chat-tool-group]", count: 1)
    expect(page).to have_css("[data-chat-tool-group-summary]", exact_text: "120 tool actions")
    expect(page).to have_no_link("Load earlier tool actions")
  end

  it "keeps the loaded count accurate during live append and fallback cleanup" do
    append_live_card
    expect(page).to have_css("[data-chat-tool-group-summary]", exact_text: "51 tool actions shown")
    remove_live_card
    expect(page).to have_css("[data-chat-tool-group-summary]", exact_text: "50 tool actions shown")
    expect(page).to have_css("[data-chat-tool-group]", count: 1)
    expect(page).to have_link("Load earlier tool actions")
  end

  def insert_tool_history
    now = 1.minute.ago
    ChatMessage.insert_all!(120.times.map do |index|
      { chat_session_id: chat_session.id, role: "tool", tool_name: "search", tool_result: { "stdout" => "Result #{index}" },
        metadata: {}, external_id: SecureRandom.uuid, created_at: now + index / 1000.0, updated_at: now }
    end)
  end

  def append_live_card
    page.execute_script(<<~JS)
      const root = document.querySelector('[data-controller~="chat"]')
      const controller = window.Stimulus.getControllerForElementAndIdentifier(root, 'chat')
      const card = document.createElement('div')
      card.innerHTML = '<div data-chat-tool-card data-test-live-tool>Live tool</div>'
      controller.appendGroupedToolCard(card)
    JS
  end

  def remove_live_card
    page.execute_script(<<~JS)
      const root = document.querySelector('[data-controller~="chat"]')
      const controller = window.Stimulus.getControllerForElementAndIdentifier(root, 'chat')
      controller.removeToolCard(document.querySelector('[data-test-live-tool]').parentElement)
    JS
  end
end
