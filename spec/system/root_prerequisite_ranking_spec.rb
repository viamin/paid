# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Root prerequisite ranking", type: :system do
  include Warden::Test::Helpers

  def partial_closeout_issue(project:, number:, root:)
    issue = create(:issue, project:, github_number: number, paid_state: "in_progress")
    create(:issue_dependency, issue:, depends_on_issue: root)
    create(:issue, :pull_request, project:, github_number: number + 10, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id)
    issue
  end

  def visibility_graph(visible_project:, hidden_project:)
    visible_root = create(:issue, project: visible_project, github_number: 21, paid_state: "in_progress")
    blocked = create(:issue, project: visible_project, github_number: 22, paid_state: "in_progress")
    leaked_root = create(:issue, project: visible_project, github_number: 24, paid_state: "in_progress")
    hidden_middle = create(:issue, project: hidden_project, github_number: 31, paid_state: "in_progress")
    create(:issue_dependency, issue: blocked, depends_on_issue: visible_root)
    create(:issue_dependency, issue: blocked, depends_on_issue: hidden_middle)
    create(:issue_dependency, issue: hidden_middle, depends_on_issue: leaked_root)
    create(:issue, :pull_request, project: visible_project, github_number: 23, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: blocked.id)
    blocked
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "renders the current partial-closeout queue ranking without changing dependency state" do
    account = create(:account)
    user = create(:user, :owner, account:, password: "password123")
    project = create(:project, account:, created_by: user, auto_pick_enabled: true, active: true,
      owner: "acme", repo: "alpha")
    root = create(:issue, project:, github_number: 1, paid_state: "in_progress")
    blocked = create(:issue, project:, github_number: 2, paid_state: "in_progress")
    create(:issue_dependency, issue: blocked, depends_on_issue: root)
    create(:issue, :pull_request, project:, github_number: 3, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: blocked.id)

    Warden.test_mode!
    login_as(user, scope: :user)
    visit inbox_entry_path("partial_closeout:#{blocked.id}", project_id: project.id,
      kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    expect(page).to have_css("[data-root-prerequisite-ranking]", text: "Highest-leverage root prerequisites")
    expect(page).to have_text("#1 → #2")
    expect(blocked.reload.blocking_issues).to contain_exactly(root)
  ensure
    Warden.test_reset!
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "renders ranking for the initially selected partial closeout on the index" do
    account = create(:account)
    user = create(:user, :owner, account:, password: "password123")
    project = create(:project, account:, created_by: user, auto_pick_enabled: true, active: true)
    root = create(:issue, project:, github_number: 1, paid_state: "in_progress")
    blocked = partial_closeout_issue(project:, number: 2, root:)

    Warden.test_mode!
    login_as(user, scope: :user)
    visit inbox_path(project_id: project.id, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    expect(page).to have_css("[data-root-prerequisite-ranking]", text: "Highest-leverage root prerequisites")
    expect(page).to have_text("#1 → #2")
    expect(blocked.reload.blocking_issues).to contain_exactly(root)
  ensure
    Warden.test_reset!
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "excludes personally removed partial-closeout work from ranking reach" do
    account = create(:account)
    user = create(:user, :owner, account:, password: "password123")
    project = create(:project, account:, created_by: user, auto_pick_enabled: true, active: true)
    root = create(:issue, project:, github_number: 1, paid_state: "in_progress")
    visible = partial_closeout_issue(project:, number: 2, root:)
    removed = partial_closeout_issue(project:, number: 3, root:)
    removed_entry = Inbox::Queue.find_entry(user:, entry_id: "partial_closeout:#{removed.id}")
    Inbox::Removals::Remove.call(entry: removed_entry, user:)

    Warden.test_mode!
    login_as(user, scope: :user)
    visit inbox_entry_path("partial_closeout:#{visible.id}", kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    within("[data-root-prerequisite-ranking]") do
      expect(page).to have_text("unlocks 1 blocked issue")
      expect(page).to have_no_text("#1 → #3")
    end
  ensure
    Warden.test_reset!
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "shows exclusion diagnostics when no prerequisite can be ranked" do
    account = create(:account)
    user = create(:user, :owner, account:, password: "password123")
    project = create(:project, account:, created_by: user, auto_pick_enabled: true, active: true)
    first = create(:issue, project:, github_number: 11, paid_state: "in_progress")
    second = create(:issue, project:, github_number: 12, paid_state: "in_progress")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    create(:issue, :pull_request, project:, github_number: 13, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: first.id)

    Warden.test_mode!
    login_as(user, scope: :user)
    visit inbox_entry_path("partial_closeout:#{first.id}", kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    expect(page).to have_css("[data-root-prerequisite-ranking]", text: "Not ranked: 2 cycle")
  ensure
    Warden.test_reset!
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "does not rank or render paths through a project outside the operator's visible lane" do
    account = create(:account)
    user = create(:user, :owner, account:, password: "password123")
    visible_project = create(:project, account:, created_by: user, auto_pick_enabled: true, active: true)
    hidden_project = create(:project, account:, created_by: create(:user, account:), auto_pick_enabled: true, active: true)
    visible_blocked = visibility_graph(visible_project:, hidden_project:)

    Warden.test_mode!
    login_as(user, scope: :user)
    visit inbox_entry_path("partial_closeout:#{visible_blocked.id}", kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    within("[data-root-prerequisite-ranking]") do
      expect(page).to have_text("#21")
      expect(page).to have_no_text("#31")
      expect(page).to have_no_text("#24")
    end
  ensure
    Warden.test_reset!
  end
end
