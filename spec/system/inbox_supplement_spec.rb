# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec OPERATOR-INBOX-017 @spec OPERATOR-INBOX-011 @spec OPERATOR-INBOX-015
RSpec.describe "Inbox supplementary context", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:project) do
    create(:project, account: account, created_by: user, active: true,
      allowed_github_usernames: [ "collaborator" ])
  end
  let(:questions) { "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. What behavior is expected?" }
  let(:github_client) { instance_double(GithubClient) }
  let(:first_issue) { create(:issue, :needs_input, project: project, title: "First question", body: questions) }
  let(:second_issue) { create(:issue, :needs_input, project: project, title: "Second question", body: questions) }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    comment = double(body: "#{questions}\n\n## Current context\nExisting behavior is documented.",
      user: double(login: "collaborator"))
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:issue_comments).and_return([ comment ])
    first_issue
    second_issue
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  it "loads context beside the form and replaces it when another entry is selected" do
    page.driver.resize(1440, 1000)
    visit inbox_path(kind: "clarifying_questions")

    expect(page).to have_css("[data-testid='inbox-clarifying-context']", text: "Existing behavior is documented.")
    expect(page).to have_button("Submit Answers")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('[data-testid=inbox-question-layout]')).display")).to eq("grid")

    within("#inbox-list") { click_link "Second question", exact: false }

    within("#inbox-detail") do
      expect(page).to have_css("h2", text: "Second question")
      expect(page).to have_css("[data-testid='inbox-clarifying-context']", text: "Existing behavior is documented.", count: 1)
    end
  end

  # @spec OPERATOR-INBOX-017 @spec OPERATOR-INBOX-003
  it "loads supplementary context after opening a detail on mobile and returns to the queue" do
    page.driver.resize(390, 844)
    visit inbox_path
    expect(page).to have_css("#inbox-list", text: "Second question")
    expect(page).to have_no_css("#inbox-detail-pane", visible: true)

    within("#inbox-list") { click_link "Second question", exact: false }

    expect(page).to have_css("#inbox-detail h2", text: "Second question")
    expect(page).to have_css("[data-testid='inbox-clarifying-context']", text: "Existing behavior is documented.")
    expect(page).to have_button("Submit Answers")
    click_link "Back to queue"
    expect(page).to have_css("#inbox-list", text: "Second question")
  end

  # @spec OPERATOR-INBOX-015
  it "refreshes the whole inbox when a clicked entry has left a nonempty queue" do
    page.driver.resize(1440, 1000)
    visit inbox_path
    expect(page).to have_css("#inbox-list", text: "Second question")
    second_issue.update_columns(github_state: "closed")

    within("#inbox-list") { click_link "Second question", exact: false }

    expect(page).to have_css("#inbox-list", text: "First question")
    expect(page).to have_no_css("#inbox-list", text: "Second question")
    expect(page).to have_no_content("Content missing")
  end

  # @spec OPERATOR-INBOX-015
  it "shows the empty state when the last displayed entries leave the queue" do
    page.driver.resize(1440, 1000)
    visit inbox_path
    expect(page).to have_css("#inbox-list", text: "Second question")
    first_issue.update_columns(github_state: "closed")
    second_issue.update_columns(github_state: "closed")

    within("#inbox-list") { click_link "Second question", exact: false }

    expect(page).to have_content("Inbox clear")
    expect(page).to have_no_content("Content missing")
    expect(page).to have_no_css("#inbox-list")
  end
end
