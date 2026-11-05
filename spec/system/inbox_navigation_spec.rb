# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec OPERATOR-INBOX-026
RSpec.describe "Inbox member navigation", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project) do
    create(:project, account:, created_by: user, owner: "acme", repo: "alpha",
      auto_pick_enabled: true, active: true)
  end
  let(:questions_body) do
    "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. What behavior is expected?\n"
  end
  let!(:first_issue) { create(:issue, :needs_input, project:, title: "First question", body: questions_body) }
  let!(:second_issue) { create(:issue, :needs_input, project:, title: "Second question", body: questions_body) }
  let(:github_client) { instance_double(GithubClient, issue_comments: []) }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    allow(GithubClient).to receive(:new).and_return(github_client)
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  def member_path(issue)
    inbox_entry_path("#{Inbox::Queue::CLARIFYING_QUESTIONS_KIND}:#{issue.id}",
      project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
  end

  def install_clipboard_spy
    page.execute_script(<<~JAVASCRIPT)
      window.__copiedInboxLink = null
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: (value) => { window.__copiedInboxLink = value; return Promise.resolve() } }
      })
    JAVASCRIPT
  end

  it "keeps the first collection selection shareable and advances subsequent selection through browser history" do
    page.driver.resize(1440, 1000)
    visit inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    expect(page).to have_css("#inbox-detail h2", text: "First question")
    expect(page).to have_current_path(inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND))

    within("#inbox-list") { click_link "Second question" }
    expect(page).to have_css("#inbox-detail h2", text: "Second question")
    expect(page).to have_current_path(member_path(second_issue))

    page.go_back
    expect(page).to have_current_path(inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND))
    expect(page).to have_css("#inbox-detail h2", text: "First question")

    page.go_forward
    expect(page).to have_current_path(member_path(second_issue))
    expect(page).to have_css("#inbox-detail h2", text: "Second question")
  end

  it "copies the canonical member URL for the first collection selection" do
    visit inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
    expect(page).to have_css("#inbox-detail h2", text: "First question")

    install_clipboard_spy
    copy_button = find_button("Copy link to this item")
    expect(copy_button["aria-describedby"]).to eq("inbox-copy-link-status")
    click_button "Copy link to this item"

    expect(page).to have_css("#inbox-copy-link-status", text: "Link copied.")
    expect(page.evaluate_script("window.__copiedInboxLink")).to end_with(member_path(first_issue))
  end

  it "uses the member URL for a dependency cycle and retains it on mobile" do
    first = create(:issue, project:, github_state: "open", title: "Cycle first")
    second = create(:issue, project:, github_state: "open", title: "Cycle second")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle_entry = Inbox::Queue.call(user:, kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND).sole

    page.driver.resize(390, 844)
    visit inbox_path(kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND)
    expect(page).to have_no_css("#inbox-detail-pane", visible: true)

    within("#inbox-list") { click_link "Dependency cycle" }
    expect(page).to have_css("#inbox-detail h2", text: "Dependency cycle")

    install_clipboard_spy
    click_button "Copy link to this item"
    expect(page.evaluate_script("window.__copiedInboxLink")).to end_with(inbox_entry_path(cycle_entry.id,
      kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND))

    expect(page).to have_current_path(inbox_entry_path(cycle_entry.id, kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND))
    expect(page).to have_css("#inbox-detail h2", text: "Dependency cycle")
  end

  it "uses the existing safe fallback when a copied member URL is no longer actionable" do
    visit member_path(first_issue)
    expect(page).to have_css("#inbox-detail h2", text: "First question")

    first_issue.update_columns(github_state: "closed")
    visit member_path(first_issue)

    expect(page).to have_current_path(inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND))
    expect(page).to have_no_css("#inbox-detail h2", text: "First question")
  end
end
