# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Root prerequisite ranking", type: :system do
  include Warden::Test::Helpers

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
end
