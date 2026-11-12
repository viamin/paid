# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec OPERATOR-INBOX-027
RSpec.describe "Inbox detail action area", system_driver: :paid_cuprite, type: :system do
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
  let!(:issue) { create(:issue, :needs_input, project:, title: "Action area question", body: questions_body) }
  let(:github_client) { instance_double(GithubClient, issue_comments: []) }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    allow(GithubClient).to receive(:new).and_return(github_client)
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  def visit_detail(width:)
    page.current_window.resize_to(width, 844)
    visit inbox_entry_path("clarifying_questions:#{issue.id}", project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
  end

  it "keeps every rendered action available in a sticky desktop action area" do
    visit_detail(width: 1440)

    action_area = find("[data-testid='inbox-item-actions']")
    expect(action_area[:class]).to include("sticky")
    expect(action_area[:class]).to include("top-0")
    expect(action_area["aria-label"]).to eq("Inbox item actions")
    expect(action_area).to have_button("Submit Answers")
    expect(action_area).to have_button("Remove from Inbox")

    source_form = find("form[action='#{project_issue_clarifying_questions_path(project, issue)}']")
    projected_submit = action_area.find_button("Submit Answers")
    expect(projected_submit[:form]).to eq(source_form[:id])
  end

  it "wraps keyboard-reachable actions in the sticky narrow-screen action area" do
    visit_detail(width: 390)

    action_area = find("[data-testid='inbox-item-actions']")
    expect(action_area[:class]).to include("flex-wrap")
    expect(action_area).to have_button("Submit Answers")
    expect(action_area).to have_button("Remove from Inbox")
  end
end
