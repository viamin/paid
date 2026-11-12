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
  let!(:first_issue) do
    create(:issue, :needs_input, project:, title: "First question", body: questions_body,
      needs_input_since: 2.hours.ago)
  end
  let(:second_issue) do
    create(:issue, :needs_input, project:, title: "Second question", body: questions_body,
      needs_input_since: 1.hour.ago)
  end
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

  def ordered_issues
    second_issue
    Inbox::Queue.call(user:, project:, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND).map(&:issue)
  end

  def completed_cycle_analysis
    issues = Array.new(3) { create(:issue, project:, github_state: "open") }
    create_legacy_issue_dependency(issue: issues[0], depends_on_issue: issues[1],
      declaration_source: "issue_comment", declaration_url: "https://github.com/acme/alpha/issues/1#issuecomment-42")
    create_legacy_issue_dependency(issue: issues[1], depends_on_issue: issues[2])
    create_legacy_issue_dependency(issue: issues[2], depends_on_issue: issues[0])
    cycle = Issues::DependencyCycles.call(account:).sole
    snapshot = CycleAnalyses::Snapshot.call(cycle:)
    removal = snapshot.fetch("effective_edges").find { |edge| edge["from_issue_id"] == issues[0].id }
    recommendation = {
      "summary" => "The dependency is obsolete.",
      "candidates" => [ {
        "declaration_changes" => [ { "edge_id" => removal.fetch("id"), "action" => "remove" } ],
        "evidence" => [ "The target issue was closed as a duplicate." ],
        "tradeoffs" => [ "The declaring issue may start earlier." ],
        "missing_or_conflicting_intent" => [],
        "acyclic" => true
      } ]
    }
    create(:agent_run, status: "completed", project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot },
      verification_result: { CycleAnalyses::RESULT_KEY => { "recommendation" => recommendation } })
    [ cycle, issues ]
  end

  it "keeps the first collection selection shareable and advances subsequent selection through browser history" do
    initial_issue, next_issue = ordered_issues
    page.current_window.resize_to(1440, 1000)
    visit inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    expect(page).to have_css("#inbox-detail h2", text: initial_issue.title)
    expect(page).to have_current_path(inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND))

    within("#inbox-list") { click_link next_issue.title }
    expect(page).to have_css("#inbox-detail h2", text: next_issue.title)
    expect(page).to have_current_path(member_path(next_issue))

    page.go_back
    expect(page).to have_current_path(inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND))
    expect(page).to have_css("#inbox-detail h2", text: initial_issue.title)

    page.go_forward
    expect(page).to have_current_path(member_path(next_issue))
    expect(page).to have_css("#inbox-detail h2", text: next_issue.title)
  end

  it "copies the canonical member URL for the first collection selection" do
    initial_issue = ordered_issues.first
    visit inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
    expect(page).to have_css("#inbox-detail h2", text: initial_issue.title)

    copy_button = find_button("Copy link to this item")
    expect(copy_button["aria-describedby"]).to eq("inbox-copy-link-status")
    expect(copy_button["data-inbox-master-detail-copy-link-url"]).to eq(member_path(initial_issue))
    click_button "Copy link to this item"

    expect(page).to have_css("#inbox-copy-link-status", text: "Link copied.")
  end

  it "uses the member URL for a dependency cycle and retains it on mobile" do
    first = create(:issue, project:, github_state: "open", title: "Cycle first")
    second = create(:issue, project:, github_state: "open", title: "Cycle second")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle_entry = Inbox::Queue.call(user:, kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND).sole

    page.current_window.resize_to(390, 844)
    visit inbox_path(kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND)
    expect(page).to have_no_css("#inbox-detail-pane", visible: true)

    within("#inbox-list") { click_link "Dependency cycle" }
    expect(page).to have_css("#inbox-detail h2", text: "Dependency cycle")

    copy_button = find_button("Copy link to this item")
    expect(copy_button["data-inbox-master-detail-copy-link-url"]).to eq(inbox_entry_path(cycle_entry.id,
      kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND))
    click_button "Copy link to this item"
    expect(page).to have_css("#inbox-copy-link-status", text: "Link copied.")

    expect(page).to have_current_path(inbox_entry_path(cycle_entry.id, kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND))
    expect(page).to have_css("#inbox-detail h2", text: "Dependency cycle")
  end

  # @spec AUTO-PICK-QUEUE-024
  it "keeps a completed cycle-repair proposal understandable on a narrow screen" do
    cycle, issues = completed_cycle_analysis
    from_ref = "#{project.full_name}##{issues[0].github_number}"
    to_ref = "#{project.full_name}##{issues[1].github_number}"

    page.current_window.resize_to(390, 844)
    visit inbox_entry_path(cycle.id, kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND)

    expect(page).to have_text("The dependency is obsolete.")
    expect(page).to have_text("Remove the dependency declared by #{from_ref} → #{to_ref}")
    expect(page).to have_button("Remove the #{to_ref} dependency declared in a trusted comment on #{from_ref}")
    expect(page).to have_text("Before:")
    expect(page).to have_text("After:")
    expect(page).to have_no_text('"declaration_changes"')
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
