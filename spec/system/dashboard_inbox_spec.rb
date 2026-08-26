# frozen_string_literal: true

require "rails_helper"

# System-level coverage of the inbox split-pane page. Verifies that the
# desktop split is rendered with both panes, that the inline one-page form
# is present, and that the master/detail collapse is wired for mobile via
# the inbox-master-detail Stimulus controller.
RSpec.describe "Dashboard inbox split pane", system_driver: :rack_test, type: :system do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account: account, email: "owner@example.com", password: "password123") }
  let!(:project) do
    create(:project, account: account, created_by: user, owner: "acme", repo: "alpha",
      auto_pick_enabled: true, active: true)
  end

  let(:questions_body) do
    <<~BODY
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
      2. Should this be behind a flag?
    BODY
  end

  def sign_in_as(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  it "renders the desktop split-pane with the inline one-page answer form" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    sign_in_as(user)
    visit dashboard_inbox_path(
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    expect(page).to have_content("Inbox")
    expect(page).to have_content("Alpha question")
    form = page.find(%(form[action="#{project_issue_clarifying_questions_path(project, project.issues.first)}"]))

    expect(form).to have_field("inbox", type: :hidden, with: "1")
    expect(form).to have_field("inbox_project_id", type: :hidden, with: project.id.to_s)
    expect(form).to have_field("inbox_kind", type: :hidden, with: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
    expect(form).to have_css("textarea[name='answers[]']", count: 2)
    expect(form).to have_button("Submit Answers")
  end

  it "embeds an empty inbox_kind when the All tab is active so the submit preserves the mixed scope" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    sign_in_as(user)
    visit dashboard_inbox_path(project_id: project.id)

    form = page.find(%(form[action="#{project_issue_clarifying_questions_path(project, project.issues.first)}"]))

    expect(form).to have_field("inbox_kind", type: :hidden, with: "")
  end

  it "wires the mobile master-detail collapse via a Stimulus controller" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    sign_in_as(user)
    visit dashboard_inbox_path(
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      view: "detail",
      entry_kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      entry_id: project.issues.first.id
    )

    master_detail = page.find("[data-controller~='inbox-master-detail']", visible: false)

    expect(master_detail["data-inbox-master-detail-detail-open-value"]).to eq("true")
    expect(page).to have_link("Back to queue")
  end

  it "renders the empty inbox state without a list or detail frame" do
    sign_in_as(user)
    visit dashboard_inbox_path

    expect(page).to have_content("Inbox clear")
    expect(page).to have_no_css("turbo-frame#inbox-detail")
  end

  it "renders the read-only question list with a GitHub link when the entry is a PR" do
    create(:issue, :pull_request, :needs_input, project: project, title: "PR question", body: questions_body)
    pr = project.issues.first

    sign_in_as(user)
    visit dashboard_inbox_path(
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      view: "detail",
      entry_kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      entry_id: pr.id
    )

    expect(page).to have_no_css("textarea[name='answers[]']")
    expect(page).to have_no_button("Submit Answers")
    expect(page).to have_content("Answer these questions on GitHub. The inbox answer form only supports issues.")
    expect(page).to have_link("View Pull Request", href: "#{project.github_url}/pull/#{pr.github_number}")
  end
end
