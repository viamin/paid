# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec INBOX-FOUNDATION-010
# The filters dialog narrows Type and Project options client-side so the
# operator cannot build a combination that renders an empty list. The
# project-name search and that narrowing are two predicates over the same
# `option.hidden` state, so they must compose instead of the last writer
# clobbering the first (#4278 review): searching must not re-show projects
# the selected type excluded, and changing the type must not re-show
# projects the search excluded. rack_test cannot execute Stimulus, so this
# drives a real browser.
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

  def assert_project_option_state(project, visibility)
    selector = "label[data-project-name='#{project.full_name.downcase}']"
    expect(page).to have_selector(selector, visible: visibility)
  end

  it "keeps the project search applied when the selected type changes" do
    open_filters
    fill_in "Search projects", with: "beta"
    choose "Clarifying Questions"

    # alpha carries clarifying-question items, so the type narrowing alone
    # would re-show it — but the pending "beta" search must keep it hidden.
    assert_project_option_state(project_a, :hidden)
    assert_project_option_state(project_b, :visible)
  end

  it "keeps the type narrowing applied when the project search runs" do
    open_filters
    choose "Manual Review"
    fill_in "Search projects", with: "alpha"

    # alpha has no manual_review items, so matching the search query must
    # not re-offer it as a project option (that combination is empty).
    assert_project_option_state(project_a, :hidden)
    assert_project_option_state(project_b, :hidden)
  end

  it "hides a searched-out project selection without clearing it" do
    open_filters
    choose "acme/beta"
    fill_in "Search projects", with: "alpha"

    assert_project_option_state(project_b, :hidden)
    radio = page.find("input[name='project_id'][value='#{project_b.id}']", visible: :all)
    expect(radio).to be_checked
  end

  it "keeps a newly selected type when it clears an incompatible project" do
    open_filters
    choose "acme/alpha"
    choose "Manual Review"

    expect(page).to have_checked_field("Manual Review")
    expect(page).to have_checked_field("All projects")
    assert_project_option_state(project_a, :hidden)
    assert_project_option_state(project_b, :visible)
  end
end
