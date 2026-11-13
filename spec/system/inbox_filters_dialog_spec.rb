# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec INBOX-FOUNDATION-010
# The dialog is a permanent browser flow because it verifies multi-value GET
# controls, union-aware availability narrowing, and server-side search.
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

  def project_option(project)
    "label[data-project-name='#{project.full_name.downcase}']"
  end

  def kind_option(kind)
    "label[data-inbox-filters-target='kindOption'] input[value='#{kind}']"
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

  # @spec INBOX-FOUNDATION-012
  it "submits multiple projects, multiple kinds, and server-side search" do
    open_filters
    check "acme/alpha"
    check "acme/beta"
    check "Clarifying Questions"
    check "Manual Review"
    fill_in "Search", with: "Beta"
    click_button "Apply filters"

    query = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
    expect(query).to include(
      "project_ids" => contain_exactly(project_a.id.to_s, project_b.id.to_s),
      "kinds" => contain_exactly(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, Inbox::Queue::MANUAL_REVIEW_KIND),
      "q" => { "text_cont" => "Beta" }
    )
    expect(page).to have_content("Beta question")
    expect(page).not_to have_content("Alpha question")
  end

  # @spec INBOX-FOUNDATION-010
  it "narrows projects against the union of selected kinds" do
    open_filters
    check "Clarifying Questions"
    check "Manual Review"

    expect(page).to have_selector(project_option(project_a), visible: :visible)
    expect(page).to have_selector(project_option(project_b), visible: :visible)

    uncheck "Clarifying Questions"

    expect(page).to have_selector(project_option(project_a), visible: :hidden)
    expect(page).to have_selector(project_option(project_b), visible: :visible)
  end

  # @spec INBOX-FOUNDATION-010
  it "narrows kinds against the union of selected projects" do
    open_filters
    check "acme/alpha"
    check "acme/beta"

    expect(page).to have_selector(kind_option(Inbox::Queue::MANUAL_REVIEW_KIND), visible: :visible)

    uncheck "acme/beta"

    expect(page).to have_selector(kind_option(Inbox::Queue::MANUAL_REVIEW_KIND), visible: :hidden)
    expect(page).to have_selector(kind_option(Inbox::Queue::CLARIFYING_QUESTIONS_KIND), visible: :visible)
  end

  # @spec INBOX-FOUNDATION-010
  it "composes project-name search with availability narrowing" do
    open_filters
    check "Manual Review"
    fill_in "Search projects", with: "alpha"

    expect(page).to have_selector(project_option(project_a), visible: :hidden)
    expect(page).to have_selector(project_option(project_b), visible: :hidden)
  end
end
