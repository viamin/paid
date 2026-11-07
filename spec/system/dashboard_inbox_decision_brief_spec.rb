# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# System-level coverage of the inbox decision brief (#4864): the brief is the
# first thing on a selected detail, submitting an action moves the operator to
# the next item with that item's own context, and evidence stays behind a
# named disclosure. Runs on rack_test because every assertion is server
# rendered; the disclosure element itself is native HTML.
RSpec.describe "Inbox decision brief", type: :system do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account: account, email: "owner@example.com", password: "password123") }
  let!(:alpha_project) do
    create(:project, account: account, created_by: user, owner: "acme", repo: "alpha",
      auto_pick_enabled: true, active: true)
  end
  let!(:beta_project) do
    create(:project, account: account, created_by: user, owner: "acme", repo: "beta",
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
  let(:github_client) do
    instance_double(GithubClient,
      issue_comments: [],
      remove_label_from_issue: true,
      add_comment: OpenStruct.new(html_url: "https://github.com/acme/alpha/issues/1#comment"))
  end

  before do
    driven_by(:rack_test)
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  def sign_in_as(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  def submit_the_clarifying_answers!(project, issue)
    within("form[action='#{project_issue_clarifying_questions_path(project, issue)}']") do
      answers = page.all("textarea[name='answers[]']")
      answers[0].set("Export as CSV")
      answers[1].set("No flag")
      click_button "Submit Answers"
    end
  end

  it "opens a selected item with the brief on top and evidence behind a named disclosure" do
    # @spec INBOX-DECISION-BRIEF-003 INBOX-DECISION-BRIEF-005
    issue = create(:issue, :needs_input, project: alpha_project, title: "Alpha question",
      body: questions_body)

    sign_in_as(user)
    visit inbox_entry_path("clarifying_questions:#{issue.id}")

    brief = page.find("[data-testid='inbox-decision-brief']")
    expect(brief).to have_selector("[data-testid='inbox-brief-goal']", text: "Alpha question")
    expect(brief).to have_selector("[data-testid='inbox-brief-decision']")
    expect(brief).to have_selector("[data-testid='inbox-brief-question']", text: "What is the expected behavior?")

    disclosure = brief.find("details[data-testid='inbox-brief-evidence']")
    expect(disclosure.find("summary")).to be_present
    expect(disclosure).to have_content("Question: What is the expected behavior?")
  end

  it "moves to the next project's item with its own context after submitting answers" do
    # @spec INBOX-DECISION-BRIEF-008
    alpha_issue = create(:issue, :needs_input, project: alpha_project, title: "Alpha question",
      body: questions_body, needs_input_since: 3.days.ago)
    beta_issue = create(:issue, :needs_input, project: beta_project, title: "Beta question",
      body: questions_body, needs_input_since: 1.day.ago)
    create(:inbox_history_event, account: account, project: beta_project,
      subject_key: "issue:#{beta_project.id}:#{beta_issue.github_number}",
      event_key: "plan-approved", result: "completed", occurred_at: 2.days.ago,
      metadata: { action: "Plan approved" })

    sign_in_as(user)
    visit inbox_entry_path("clarifying_questions:#{alpha_issue.id}")
    submit_the_clarifying_answers!(alpha_project, alpha_issue)

    expect(page).to have_current_path(inbox_entry_path("clarifying_questions:#{beta_issue.id}"))
    expect(page).to have_selector("[data-testid='inbox-brief-goal']", text: "Beta question")
    expect(page).to have_selector("[data-testid='inbox-brief-last-decision']", text: "Plan approved")
    expect(page).to have_content(beta_project.full_name)
    within("#inbox-detail-pane") do
      expect(page).to have_no_content("Alpha question")
    end
  end

  it "keeps one primary action visually clear on an action-required item" do
    # @spec INBOX-DECISION-BRIEF-003
    issue = create(:issue, project: alpha_project, title: "Blocked rollout")
    create(:notification, :error, account: account, subject: issue, blocking: true,
      title: "Re-grant the token", description: "The stored token expired.",
      action_url: edit_project_path(alpha_project),
      metadata: { "recommended_action" => "Rotate the token in project settings." })

    sign_in_as(user)
    visit inbox_entry_path("action_required:#{Notification.last.id}")

    primary = page.find("[data-testid='inbox-brief-primary-action']")
    expect(primary.text).to include("Open linked action")
    expect(primary["data-turbo-frame"]).to eq("_top")
  end
end
