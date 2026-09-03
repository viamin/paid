# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# Regression coverage for #3798: the inbox-master-detail Stimulus controller
# used to raise on load ("Cannot read properties of undefined (reading
# 'matches')") because its value-change callback ran before connect()
# initialized the media query, which left the whole page's Stimulus
# lifecycle broken and the global chat-popup controller inert. That only
# happens on an inbox page that renders both master-detail pane targets, so
# this seeds an entry (an empty inbox skips both targets entirely). The
# rack_test-driven inbox specs can't catch Stimulus failures, so this uses a
# real browser.
RSpec.describe "Inbox chat popup", :js, system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "alpha") }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    create(
      :issue,
      :needs_input,
      project:,
      title: "Alpha question",
      body: "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. What is the expected behavior?\n"
    )

    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  it "opens and loads the popup chat session from the inbox page" do
    # @spec OPERATOR-INBOX-003A
    # The driver is configured with `js_errors: true`, so if the
    # inbox-master-detail controller throws during Stimulus lifecycle
    # (the original bug), Cuprite raises and this example fails outright.
    visit inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    expect(page).to have_content("Inbox")
    button = page.find("[data-chat-popup-target='button']")
    expect(button["aria-expanded"]).to eq("false")

    button.click

    expect(page).to have_css("[data-chat-popup-target='button'][aria-expanded='true']")
    expect(page).to have_no_css("[data-chat-popup-target='panel'].hidden")
    expect(page).to have_css("[data-chat-popup-target='content'] form, [data-chat-popup-target='content'] [data-chat-target]")

    expect(account.chat_sessions.count).to eq(1)
  end

  it "shows both panes on desktop and collapses to a single pane below the 1024px breakpoint" do
    # @spec OPERATOR-INBOX-003
    page.current_window.resize_to(1280, 800)
    visit inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    list = page.find("[data-inbox-master-detail-target='list']", visible: :all)
    detail_section = page.find("[data-inbox-master-detail-target='detailSection']", visible: :all)
    expect(list).to be_visible
    expect(detail_section).to be_visible

    page.current_window.resize_to(375, 812)

    expect(list).to be_visible
    expect(detail_section).to_not be_visible

    page.find("[data-inbox-master-detail-target='row']", match: :first).click

    expect(page).to have_content("Back to queue")
    list = page.find("[data-inbox-master-detail-target='list']", visible: :all)
    detail_section = page.find("[data-inbox-master-detail-target='detailSection']", visible: :all)
    expect(list).to_not be_visible
    expect(detail_section).to be_visible

    click_link "Back to queue"

    list = page.find("[data-inbox-master-detail-target='list']", visible: :all)
    detail_section = page.find("[data-inbox-master-detail-target='detailSection']", visible: :all)
    expect(list).to be_visible
    expect(detail_section).to_not be_visible
  end
end
