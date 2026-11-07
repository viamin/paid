# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec INBOX-DECISION-BRIEF-002 INBOX-DECISION-BRIEF-003
# @spec INBOX-DECISION-BRIEF-004 INBOX-DECISION-BRIEF-005
# @spec INBOX-DECISION-BRIEF-006 INBOX-DECISION-BRIEF-008
RSpec.describe "Inbox decision brief" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true,
      owner: "acme", repo: "alpha")
  end
  let(:second_project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true,
      owner: "acme", repo: "beta")
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
    sign_in user
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(
      ref: OpenStruct.new(object: OpenStruct.new(sha: "abc123")), commit: OpenStruct.new(sha: "abc123")
    )
  end

  def entry_id(entry_kind, record)
    "#{entry_kind}:#{record.id}"
  end

  def record_fresh_closeout_assessment(issue, explanation: "Close the accepted issue.")
    run = create(:agent_run, :completed, project: issue.project, issue: issue)
    assessment = PartialCloseouts::Assessment.snapshot(run, {
      "classification" => "complete",
      "criteria" => [ { "criterion" => "Pilot p95", "state" => "satisfied" } ],
      "gaps" => [],
      "next_action" => { "kind" => "close_on_github", "explanation" => explanation }
    })
    run.update!(reconciliation: { "assessment" => assessment })
  end

  describe "GET /inbox (list rows)" do
    it "names the project, work item, decision, and impact in plain language on each row" do
      # @spec INBOX-DECISION-BRIEF-002
      alpha_issue = create(:issue, :needs_input, project: project, title: "Ship the alpha export",
        body: questions_body, needs_input_since: 3.days.ago)
      create(:issue, :needs_input, project: second_project, title: "Ship the beta export",
        body: questions_body, needs_input_since: 1.day.ago)

      get inbox_path

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      brief_rows = document.css("[data-testid='inbox-list-brief']")
      expect(brief_rows.size).to eq(2)

      alpha_row = brief_rows.find { |row| row.text.include?(project.full_name) }
      expect(alpha_row).to be_present
      expect(alpha_row.text).to include("Answer 2 clarifying questions")
      expect(alpha_row.text).to include("#{project.full_name}##{alpha_issue.github_number}")
      expect(alpha_row.ancestors("li").first.text).to include("Ship the alpha export")
    end

    it "keeps raw closeout jargon out of the partial-closeout row's default copy" do
      # @spec INBOX-DECISION-BRIEF-002 INBOX-DECISION-BRIEF-004
      stalled_issue = create(:issue, project: project, github_number: 610, paid_state: "in_progress",
        title: "Partially delivered epic")
      create(:issue, :pull_request, project: project, github_number: 611, github_state: "closed",
        pr_review_phase: "merged", parent_issue: stalled_issue, created_at: 2.days.ago)

      get inbox_path(kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      brief_row = document.css("[data-testid='inbox-list-brief']").first
      expect(brief_row).to be_present
      expect(brief_row.text).not_to include("paid_state")
      expect(brief_row.text).not_to include("auto-pick")
      expect(brief_row.ancestors("li").first.text).to include("Partially delivered epic")
    end
  end

  describe "GET /inbox/:entry_id (selected detail)" do
    it "opens a clarifying question with a self-contained brief whose question is separate from the explanation" do
      # @spec INBOX-DECISION-BRIEF-003 INBOX-DECISION-BRIEF-004
      issue = create(:issue, :needs_input, project: project, title: "Ship the export", body: questions_body)

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue)),
        headers: { "Turbo-Frame" => "inbox-detail" }

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)

      brief = document.at_css("[data-testid='inbox-decision-brief']")
      expect(brief).to be_present
      ordered_landmarks = document.css("[data-testid='inbox-decision-brief'], [data-testid='inbox-question-layout']")
      expect(ordered_landmarks.first["data-testid"]).to eq("inbox-decision-brief")

      expect(document.at_css("[data-testid='inbox-brief-goal']").text).to include("Ship the export")
      expect(document.at_css("[data-testid='inbox-brief-changed']").text).to be_present
      expect(document.at_css("[data-testid='inbox-brief-decision']").text).to include("Answer 2 clarifying questions")
      expect(document.at_css("[data-testid='inbox-brief-after']").text).to be_present
      expect(document.at_css("[data-testid='inbox-brief-impact']").text).to include("#{project.full_name}##{issue.github_number}")

      question = document.at_css("[data-testid='inbox-brief-question']")
      expect(question.text).to include("What is the expected behavior?")
      expect(document.at_css("[data-testid='inbox-brief-recommendation']")).to be_nil
    end

    it "grounds an action-required recommendation in the structured metadata with one primary action" do
      # @spec INBOX-DECISION-BRIEF-003 INBOX-DECISION-BRIEF-006
      issue = create(:issue, project: project, title: "Blocked rollout")
      create(:notification, :error, account: account, subject: issue, blocking: true,
        title: "Re-grant the token", description: "The stored token expired.",
        action_url: edit_project_path(project),
        metadata: { "recommended_action" => "Rotate the token in project settings." })

      get inbox_entry_path(entry_id(Inbox::Queue::ACTION_REQUIRED_KIND, Notification.last)),
        headers: { "Turbo-Frame" => "inbox-detail" }

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)

      expect(document.at_css("[data-testid='inbox-brief-goal']").text).to include("Blocked rollout")
      expect(document.at_css("[data-testid='inbox-brief-recommendation']").text)
        .to include("Rotate the token in project settings.")

      primary = document.at_css("[data-testid='inbox-brief-primary-action']")
      expect(primary).to be_present
      expect(primary["data-turbo-frame"]).to eq("_top")
      expect(primary.text).to include("Open linked action")

      details = document.at_css("[data-testid='inbox-brief-evidence']")
      expect(details).to be_present
      expect(details.name).to eq("details")
    end

    it "separates a manual-review question from the explanation" do
      # @spec INBOX-DECISION-BRIEF-004
      issue = create(:issue, project: project, title: "Reopened bug", paid_state: "manual_review",
        manual_review_reason: "Stopped for manual review.")
      issue.update!(needs_input_questions: [ "Is the remaining scope still wanted?" ])

      get inbox_entry_path(entry_id(Inbox::Queue::MANUAL_REVIEW_KIND, issue)),
        headers: { "Turbo-Frame" => "inbox-detail" }

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)

      expect(document.at_css("[data-testid='inbox-decision-brief']")).to be_present
      question = document.at_css("[data-testid='inbox-brief-question']")
      expect(question.text).to include("Is the remaining scope still wanted?")
      expect(question.text).not_to include("Stopped for manual review")
    end

    it "grounds the partial-closeout recommendation in the recorded assessment and keeps evidence behind the disclosure" do
      # @spec INBOX-DECISION-BRIEF-003 INBOX-DECISION-BRIEF-005 INBOX-DECISION-BRIEF-006
      stalled_issue = create(:issue, project: project, github_number: 620, paid_state: "in_progress",
        title: "Partially delivered epic")
      merged_pr = create(:issue, :pull_request, project: project, github_number: 621, github_state: "closed",
        pr_review_phase: "merged", parent_issue: stalled_issue, created_at: 2.days.ago)
      record_fresh_closeout_assessment(stalled_issue)

      get inbox_entry_path(entry_id(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, stalled_issue)),
        headers: { "Turbo-Frame" => "inbox-detail" }

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)

      brief = document.at_css("[data-testid='inbox-decision-brief']")
      expect(brief).to be_present
      expect(document.at_css("[data-testid='inbox-brief-goal']").text).to include("Partially delivered epic")
      expect(document.at_css("[data-testid='inbox-brief-recommendation']").text).to include("Close the accepted issue.")

      details = document.at_css("[data-testid='inbox-brief-evidence']")
      expect(details.text).to include("##{merged_pr.github_number}")
      brief_default = brief.css(":not(details)").text
      expect(brief_default).not_to include("paid_state")
    end

    it "discloses a stale assessment instead of recommending" do
      # @spec INBOX-DECISION-BRIEF-006
      stalled_issue = create(:issue, project: project, github_number: 630, paid_state: "in_progress",
        title: "Partially delivered epic")
      create(:issue, :pull_request, project: project, github_number: 631, github_state: "closed",
        pr_review_phase: "merged", parent_issue: stalled_issue, created_at: 2.days.ago)
      record_fresh_closeout_assessment(stalled_issue, explanation: "Close the accepted issue.")
      stalled_issue.update!(title: "Partially delivered epic (renamed)", body: "The scope changed.")

      get inbox_entry_path(entry_id(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, stalled_issue)),
        headers: { "Turbo-Frame" => "inbox-detail" }

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)

      expect(document.at_css("[data-testid='inbox-brief-recommendation']")).to be_nil
      expect(document.at_css("[data-testid='inbox-brief-unknowns']").text).to match(/stale/i)
      expect(document.at_css("[data-testid='inbox-brief-question']").text).to be_present
    end
  end

  describe "POST answers (after an action)" do
    def create_two_project_question_items
      alpha_issue = create(:issue, :needs_input, project: project, title: "Ship the alpha export",
        body: questions_body, needs_input_since: 3.days.ago)
      beta_issue = create(:issue, :needs_input, project: second_project, title: "Ship the beta export",
        body: questions_body, needs_input_since: 1.day.ago)
      create(:inbox_history_event, account: account, project: second_project,
        subject_key: "issue:#{second_project.id}:#{beta_issue.github_number}",
        event_key: "plan-approved", result: "completed", occurred_at: 2.days.ago,
        metadata: { action: "Plan approved" })
      [ alpha_issue, beta_issue ]
    end

    def submit_answers!(issue, extra_params = {})
      post project_issue_clarifying_questions_path(project, issue),
        params: {
          inbox: "1",
          questions: [ "What is the expected behavior?", "Should this be behind a flag?" ],
          answers: [ "Export as CSV", "No flag" ]
        }.merge(extra_params)
    end

    it "moves to the next item with its own project, goal, and last agreed decision, preserving filters" do
      # @spec INBOX-DECISION-BRIEF-008
      alpha_issue, beta_issue = create_two_project_question_items

      submit_answers!(alpha_issue, inbox_kind: "")

      expect(response).to redirect_to(inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, beta_issue)))
      follow_redirect!

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      expect(document.at_css("[data-testid='inbox-brief-goal']").text).to include("Ship the beta export")
      expect(document.at_css("[data-testid='inbox-brief-impact']").text).to include(second_project.full_name)
      expect(document.at_css("[data-testid='inbox-brief-last-decision']").text).to include("Plan approved")
      expect(document.at_css("[data-testid='inbox-brief-goal']").text).not_to include("alpha")
    end

    it "preserves the project and kind filters the operator was using" do
      # @spec INBOX-DECISION-BRIEF-008
      alpha_issue, = create_two_project_question_items

      submit_answers!(alpha_issue,
        inbox_kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND, inbox_project_id: project.id)

      expect(response).to redirect_to(inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND))
    end
  end
end
