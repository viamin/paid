# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec OPERATOR-INBOX-027 OPERATOR-INBOX-028
RSpec.describe "Inbox filters dialog", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project_a) do
    create(:project, account:, created_by: user, owner: "acme", repo: "alpha",
      auto_pick_enabled: true, active: true)
  end
  let(:project_b) do
    create(:project, account:, created_by: user, owner: "acme", repo: "beta",
      auto_pick_enabled: true, active: true)
  end
  let(:questions_body) do
    "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. What is the expected behavior?\n"
  end
  # Factory projects ship with a github_token, so the context_markdown
  # accessor reaches for issue comments on the selected inbox entry. Stub the
  # client so the inbox page builds under WebMock without touching the
  # network.
  let(:github_client) { instance_double(GithubClient, issue_comments: []) }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    allow(GithubClient).to receive(:new).and_return(github_client)

    project_a
    project_b
    create(:issue, :needs_input, project: project_a, title: "Alpha question", body: questions_body)
    create(:issue, :needs_input, project: project_b, title: "Beta question", body: questions_body)
    create(:issue, project: project_b, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  def open_filters
    visit inbox_path
    click_button "Filters"
  end

  # @spec OPERATOR-INBOX-025
  it "loads selected detail history when its lazy frame enters view" do
    visit inbox_path(kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    expect(page).to have_content("Alpha question")
    expect(page).to have_selector("turbo-frame#inbox-detail")
    expect(page).to have_selector("form[action='#{project_issue_clarifying_questions_path(project_a, project_a.issues.first)}']")
    expect(page).to have_selector("turbo-frame#inbox-history[loading='lazy']")
    page.execute_script("document.querySelector('#inbox-history').scrollIntoView()")
    expect(page).to have_content("Action history")
  end

  # @spec OPERATOR-INBOX-025
  it "keeps a clicked row selected when the initial detail request is in flight" do
    visit inbox_path(kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
    within("#inbox-list") { click_link "Beta question" }

    expect(page).to have_selector("turbo-frame#inbox-detail h2", text: "Beta question")
    expect(page).to have_selector("turbo-frame#inbox-detail form[action='#{project_issue_clarifying_questions_path(project_b, project_b.issues.first)}']")
  end

  it "submits multiple project and kind filters in a shareable GET URL" do
    open_filters
    check "Clarifying Questions"
    check "Manual Review"
    check "acme/alpha"
    check "acme/beta"
    click_button "Apply filters"

    expect(page).to have_current_path(/q%5Bkind_in%5D%5B%5D=clarifying_questions/)
    expect(page).to have_content("Alpha question", "Beta question")
  end

  it "searches queue entries on the server with the other filters" do
    open_filters
    check "Manual Review"
    fill_in "Search inbox", with: "round limit"
    click_button "Apply filters"

    expect(page).to have_content("Round limit reached")
    expect(page).to have_current_path(/q%5Bsearch_cont%5D=round\+limit/)
  end
end
