# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec INBOX-PROGRESS-004
RSpec.describe "Inbox workflow milestones", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_merge_mode: "off", tdd_mode: "off") }
  let(:head) { "a" * 40 }
  let(:pull_request) do
    create(:issue, :pull_request, project:, title: "Review documentation", pr_review_phase: "ready",
      last_scanned_head_sha: head, auto_merge_head_sha: head, auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: { "failed" => [], "not_evaluated" => [] })
  end

  before do
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  def visit_detail
    visit inbox_entry_path("merge_approval:#{pull_request.id}")
    expect(page).to have_css('[data-testid="inbox-workflow"]')
    expect(page).to have_no_css('[data-testid="inbox-progress"]')
  end

  def inspect_merge_evidence
    summary = find('[data-progress-milestone="merge"] summary')
    summary.native.node.focus
    page.driver.browser.keyboard.type(:Enter)
    expect(page).to have_css('[data-progress-milestone="merge"][open]')
    expect(page).to have_text("Approval and merge are separate actions")
    expect(page).to have_css("code", text: head, visible: true)
    expect(page).to have_link("View on GitHub", href: pull_request.github_url)
    summary.native.node.focus
    page.driver.browser.keyboard.type(:Enter)
    expect(page).to have_no_css('[data-progress-milestone="merge"][open]')
  end

  it "keeps a manual merge distinct from approval and supports keyboard evidence inspection at narrow and desktop widths" do
    [ 320, 390, 768, 1440 ].each do |width|
      page.current_window.resize_to(width, 1000)
      visit_detail
      within('[data-testid="inbox-workflow"]') do
        expect(page).to have_text("make the manual merge decision on GitHub")
        expect(page).to have_css('[data-progress-milestone="owner_approval"] [data-progress-state="completed"]')
        expect(page).to have_css('[data-progress-milestone="merge"] [aria-current="step"]')
        expect(page).to have_no_css("details[open]")
        expect(page).to have_no_text(head)
        inspect_merge_evidence
      end
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1")).to be(true)
      expect(page.evaluate_script('document.querySelector("[data-testid=inbox-workflow]").getBoundingClientRect().right <= innerWidth + 1')).to be(true)
    end
  end

  it "shows current and stale strict-TDD decisions without converting them to merge approval" do
    project.update!(operating_mode: "human_led_feature_factory", tdd_mode: "strict")
    pull_request.update!(labels: [ "paid-tests-ready-for-review" ], tdd_review_head_sha: head)
    visit_detail
    within('[data-testid="inbox-workflow"]') do
      expect(page).to have_css('[data-progress-milestone="design"] [data-progress-state="unknown"]')
      expect(page).to have_css('[data-progress-milestone="tests"] [data-progress-state="current"]')
      expect(page).to have_css('[data-progress-milestone="merge"] [data-progress-state="blocked"]')
    end

    pull_request.update!(labels: [ "paid-tests-approved" ], tdd_review_head_sha: head, last_scanned_head_sha: "b" * 40)
    visit_detail
    expect(page).to have_css('[data-progress-milestone="tests"] [data-progress-state="stale"]')
    expect(page).to have_css('[data-progress-milestone="owner_approval"] [data-progress-state="unknown"]')
  end
end
