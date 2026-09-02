# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Inbox" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(
      :project,
      account: account,
      created_by: user,
      auto_pick_enabled: true,
      active: true,
      auto_merge_mode: "all",
      owner_reviewer_login: "viamin",
      owner: "acme",
      repo: "alpha"
    )
  end
  let(:second_project) do
    create(
      :project,
      account: account,
      created_by: user,
      auto_pick_enabled: true,
      active: true,
      auto_merge_mode: "all",
      owner_reviewer_login: "viamin",
      owner: "acme",
      repo: "beta"
    )
  end
  let(:plan_review_issue) { create(:issue, project: project, title: "Review me") }
  let(:questions_body) do
    <<~BODY
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
      2. Should this be behind a flag?
    BODY
  end

  before { sign_in user }

  def entry_id(entry_kind, record)
    "#{entry_kind}:#{record.id}"
  end

  def create_inbox_entries
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)
    create(:issue, :needs_input, project: second_project, title: "Beta question", body: questions_body)
    create(:issue, :closed, :needs_input, project: project, title: "Closed question", body: questions_body)
    create(:issue, :pull_request, :needs_input, project: project, title: "PR question", body: questions_body)
    create_merge_approval_pr(title: "Approval blocked PR", github_number: 999)
    create(
      :notification,
      :error,
      account: account,
      subject: project,
      source: "quality_auto_resume_cooldown",
      blocking: true,
      title: "Quality pause requires manual review",
      metadata: {
        "recommended_action" => "Review the quality dashboard and resume manually or adjust thresholds.",
        "remediation_steps" => [ "Open the quality dashboard", "Resume manually or adjust thresholds" ]
      }
    )
    create(
      :decomposition_decision,
      project: project,
      issue: plan_review_issue,
      workflow_id: "planning-workflow-1",
      decision_key: "planning-workflow-1:plan_review:pending",
      decision_type: "planning_outcome",
      outcome: "plan_pending_review",
      plan_data: { "tasks" => [ { "title" => "Visible task", "description" => "Visible description" } ] }
    )
  end

  # @spec OPERATOR-INBOX-001 @spec OPERATOR-INBOX-003
  it "lists clarifying-question and plan-review entries across auto-pick projects" do
    review = create_inbox_entries

    get inbox_entry_path(entry_id(Inbox::Queue::PLAN_REVIEW_KIND, review))

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Inbox", project.full_name, second_project.full_name)
    expect(response.body).to include("Alpha question", "Beta question", "PR question", "Approval blocked PR", "Review me", "Quality pause requires manual review")
    expect(response.body).to include("Visible task", "What is the expected behavior?")
    expect(response.body).not_to include("Closed question")
  end

  # @spec NOTIFICATION-SEVERITY-009
  it "renders action_required detail with remediation steps" do
    notification = create_action_required_notification

    get inbox_entry_path(
      entry_id(Inbox::Queue::ACTION_REQUIRED_KIND, notification),
      kind: Inbox::Queue::ACTION_REQUIRED_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Action Required", "Quality pause requires manual review")
    expect(response.body).to include("Review the quality dashboard and resume manually or adjust thresholds.")
    expect(response.body).to include("Open the quality dashboard", "Resume manually or adjust thresholds")
  end

  it "selects the first entry on the collection route" do
    issue = create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    frame = document.at_css("turbo-frame#inbox-detail")
    form = frame.at_css(%(form[action="#{project_issue_clarifying_questions_path(project, issue)}"]))
    master_detail = document.at_css("[data-controller~='inbox-master-detail']")

    expect(form).to be_present
    expect(master_detail["data-inbox-master-detail-detail-open-value"]).to eq("false")
  end

  it "selects the requested entry on the member route" do
    create(:issue, :needs_input, project: project, github_number: 11, body: questions_body)
    second_issue = create(:issue, :needs_input, project: project, github_number: 22, body: questions_body)

    get inbox_entry_path(
      entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, second_issue),
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    expect(response).to have_http_status(:ok)
    detail_form = Nokogiri::HTML(response.body)
      .at_css(%(form[action="#{project_issue_clarifying_questions_path(project, second_issue)}"]))

    expect(detail_form).to be_present
  end

  # @spec OPERATOR-INBOX-009
  it "redirects stale member routes to the collection route with 303" do
    create(:issue, :needs_input, project: project, title: "Live question", body: questions_body)

    get inbox_entry_path(
      "#{Inbox::Queue::CLARIFYING_QUESTIONS_KIND}:999999",
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    expect(response).to redirect_to(
      inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
    )
    expect(response).to have_http_status(:see_other)
  end

  it "marks list rows with the inbox-master-detail row target and member hrefs" do
    issue = create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    document = Nokogiri::HTML(response.body)
    link = document.at_css(%(a[href="#{inbox_entry_path(
      entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue),
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )}"]))

    expect(link).to be_present
    expect(link["data-inbox-master-detail-target"]).to eq("row")
  end

  it "supports project scoping" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)
    create(:issue, :needs_input, project: second_project, title: "Beta question", body: questions_body)

    get inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(project.full_name, "Alpha question")
    expect(response.body).not_to include(second_project.full_name)
    expect(response.body).not_to include("Beta question")
  end

  it "embeds the active inbox-kind filter in the answer form so submit preserves the tab" do
    issue = create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_path

    form = Nokogiri::HTML(response.body)
      .at_css(%(form[action="#{project_issue_clarifying_questions_path(project, issue)}"]))

    expect(form).to be_present
    expect(form.at_css(%(input[name="inbox_kind"]))["value"]).to eq("")
  end

  it "renders the answer form for PR-backed clarifying-question entries" do
    pr = create(:issue, :pull_request, :needs_input, project: project, title: "PR question", body: questions_body)

    get inbox_entry_path(
      entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, pr),
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    form = document.at_css(%(form[action="#{project_issue_clarifying_questions_path(project, pr)}"]))
    pr_link = document.at_css(%(a[href="#{project.github_url}/pull/#{pr.github_number}"]))

    expect(form).to be_present
    expect(form.css("textarea[name='answers[]']").size).to eq(2)
    expect(pr_link).to be_present
    expect(response.body).to include("View PR")
  end

  it "renders a mobile detail state when the member route is selected" do
    issue = create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_entry_path(
      entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue),
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Back to queue", "Submit Answers", "lg:grid-cols-[22rem,1fr]")
    master_detail = Nokogiri::HTML(response.body).at_css("[data-controller~='inbox-master-detail']")

    expect(master_detail["data-inbox-master-detail-detail-open-value"]).to eq("true")
  end

  it "renders merge-approval detail with the PR action and blocker summary" do
    pr = create_merge_approval_pr(title: "Approval blocked PR")

    get inbox_entry_path(
      entry_id(Inbox::Queue::MERGE_APPROVAL_KIND, pr),
      project_id: project.id,
      kind: Inbox::Queue::MERGE_APPROVAL_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Merge Approval", "PR", "Re-approve on GitHub", "View PR")
    expect(response.body).to include("Waiting for owner re-approval on the current HEAD commit")
  end

  # @spec OPERATOR-INBOX-002C
  it "lists escalated pull requests scoped to auto-pick projects" do
    ungated_project = create(:project, account: account, created_by: user, auto_pick_enabled: false, active: true)
    create_escalated_pr(title: "Escalated PR", github_number: 500)
    create_escalated_pr(title: "Not gated", github_number: 501, project: ungated_project)

    get inbox_path(kind: Inbox::Queue::ESCALATED_PR_KIND)

    expect(response.body).to include("Blocked PRs", "Escalated PR")
    expect(response.body).not_to include("Not gated")
  end

  # @spec OPERATOR-INBOX-002C
  it "renders escalated-pr detail with counters and the inbox-scoped unblock action" do
    escalated = create_escalated_pr(
      title: "Escalated PR",
      github_number: 502,
      draft_review_count: 12,
      pr_followup_count: 8
    )

    get inbox_entry_path(
      entry_id(Inbox::Queue::ESCALATED_PR_KIND, escalated),
      kind: Inbox::Queue::ESCALATED_PR_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Failure streak", "Draft rounds", "Follow-up runs", "Unblock")
    document = Nokogiri::HTML(response.body)
    form = document.at_css(
      %(form[action="#{unblock_escalation_project_agent_runs_path(project, pull_request_id: escalated.id)}"])
    )

    expect(form).to be_present
    expect(form.at_css('input[name="return_to"]')["value"]).to eq(
      inbox_path(kind: Inbox::Queue::ESCALATED_PR_KIND)
    )
  end

  # @spec OPERATOR-INBOX-002C
  it "directs an awaiting_approval escalation to GitHub re-approval instead of Unblock" do
    escalated = create_escalated_pr(
      title: "Awaiting approval PR",
      github_number: 503,
      reason: Issue::PR_ESCALATION_REASON_AWAITING_APPROVAL
    )

    get inbox_entry_path(
      entry_id(Inbox::Queue::ESCALATED_PR_KIND, escalated),
      kind: Inbox::Queue::ESCALATED_PR_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Re-approve on GitHub", "Awaiting approval")
    expect(response.body).not_to include(">Unblock<")
  end

  # @spec OPERATOR-INBOX-002D
  it "lists manual_review issues scoped to auto-pick projects" do
    ungated_project = create(:project, account: account, created_by: user, auto_pick_enabled: false, active: true)
    create_manual_review_issue(title: "Parked issue", github_number: 507)
    create_manual_review_issue(title: "Not gated", github_number: 508, project: ungated_project)

    get inbox_path(kind: Inbox::Queue::MANUAL_REVIEW_KIND)

    expect(response.body).to include("Manual Review", "Parked issue")
    expect(response.body).not_to include("Not gated")
  end

  # @spec OPERATOR-INBOX-002D @spec ISSUE-ENHANCEMENT-011
  it "renders manual_review detail with the reason and the inbox-scoped resume action" do
    parked = create_manual_review_issue(
      title: "Parked issue",
      github_number: 509,
      reason: "Structured output failed validation."
    )

    get inbox_entry_path(
      entry_id(Inbox::Queue::MANUAL_REVIEW_KIND, parked),
      kind: Inbox::Queue::MANUAL_REVIEW_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Structured output failed validation.", "Start enhancement run")
    document = Nokogiri::HTML(response.body)
    form = document.at_css(
      %(form[action="#{resume_manual_review_project_agent_runs_path(project, issue_id: parked.id)}"])
    )

    expect(form).to be_present
    expect(form.at_css('input[name="return_to"]')["value"]).to eq(
      inbox_path(kind: Inbox::Queue::MANUAL_REVIEW_KIND)
    )
  end

  # @spec OPERATOR-INBOX-006
  it "renders an unknown waiting age for a legacy entry without a timestamp" do
    issue = create(:issue, :needs_input, project: project, title: "Legacy question", body: questions_body)
    issue.update_columns(needs_input_since: nil)

    get inbox_entry_path(
      entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue),
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("[data-testid='inbox-list-waiting-age']").text.strip).to eq("Waiting —")
    expect(document.at_css("[data-testid='inbox-detail-waiting-age']").text.strip).to eq("Waiting —")
  end

  context "when a clarifying question contains markdown" do
    let(:markdown_question) { "Should `foo_bar` use **snake_case** or [camelCase](https://example.com)?" }
    let(:markdown_body) do
      <<~BODY
        <!-- paid:enhance-issue -->

        ## Clarifying questions
        1. #{markdown_question}
      BODY
    end

    it "wires the raw question text into the markdown-text controller for client-side rendering" do
      issue = create(:issue, :needs_input, project: project, title: "Markdown question", body: markdown_body)

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      question_node = Nokogiri::HTML(response.body).at_css('[data-controller="markdown-text"]')

      expect(question_node).to be_present
      expect(question_node["data-markdown-text-content-value"]).to eq(markdown_question)
      expect(response.body).to include(CGI.escapeHTML(markdown_question))
      expect(response.body).not_to include("<strong>snake_case</strong>")
    end
  end

  context "when a plan review task contains markdown" do
    let(:markdown_title) { "Wire `markdown-text` into the **inbox** partial" }
    let(:markdown_description) { "Should `description` use **markdown** or [plaintext](https://example.com)?" }
    let(:review) do
      create(
        :decomposition_decision,
        project: project,
        issue: plan_review_issue,
        workflow_id: "planning-workflow-1",
        decision_key: "planning-workflow-1:plan_review:pending",
        decision_type: "planning_outcome",
        outcome: "plan_pending_review",
        plan_data: { "tasks" => [ { "title" => markdown_title, "description" => markdown_description } ] }
      )
    end

    it "wires the raw title and description into the markdown-text controller for client-side rendering" do
      get inbox_entry_path(entry_id(Inbox::Queue::PLAN_REVIEW_KIND, review))

      content_values = Nokogiri::HTML(response.body)
        .css('[data-controller="markdown-text"]')
        .map { |node| node["data-markdown-text-content-value"] }

      expect(content_values).to include(markdown_title, markdown_description)
      expect(response.body).to include(CGI.escapeHTML(markdown_title), CGI.escapeHTML(markdown_description))
      expect(response.body).not_to include("<strong>inbox</strong>", "<strong>markdown</strong>")
    end
  end

  # @spec OPERATOR-INBOX-010
  describe "GET /inbox/count" do
    def badge_text(document, frame_id)
      document.at_css("turbo-frame##{frame_id} span")&.text&.strip
    end

    it "renders no badge pill for either frame when nothing is waiting" do
      get inbox_count_path

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)

      expect(badge_text(document, "inbox_nav_badge_desktop")).to be_nil
      expect(badge_text(document, "inbox_nav_badge_mobile")).to be_nil
    end

    it "renders the waiting count in both the desktop and mobile badge frames" do
      create(:issue, :needs_input, project: project, body: questions_body)
      create(:issue, :needs_input, project: second_project, body: questions_body)
      create_merge_approval_pr(snapshot: owner_approval_snapshot)

      get inbox_count_path

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)

      expect(badge_text(document, "inbox_nav_badge_desktop")).to eq("3")
      expect(badge_text(document, "inbox_nav_badge_mobile")).to eq("3")
    end

    it "caps the displayed count at 99+ once past the display cap" do
      101.times { |n| create(:issue, :needs_input, project: project, github_number: 1000 + n, body: questions_body) }

      get inbox_count_path

      document = Nokogiri::HTML(response.body)
      expect(badge_text(document, "inbox_nav_badge_desktop")).to eq("99+")
    end

    it "matches the Inbox page's needs-input entry count when questions parse cleanly" do
      create(:issue, :needs_input, project: project, body: questions_body)
      create(:issue, :needs_input, project: second_project, body: questions_body)

      get inbox_count_path
      badge_count = badge_text(Nokogiri::HTML(response.body), "inbox_nav_badge_desktop").to_i

      queue_size = Inbox::Queue.call(user: user).size

      expect(badge_count).to eq(queue_size)
    end

    # @spec OPERATOR-INBOX-002C
    it "includes escalated pull requests in the count badge" do
      create_escalated_pr(github_number: 504)

      get inbox_count_path
      badge_count = badge_text(Nokogiri::HTML(response.body), "inbox_nav_badge_desktop").to_i

      expect(badge_count).to eq(1)
    end
  end

  def create_merge_approval_pr(title: "Approval blocked PR", github_number: 123, snapshot: stale_approval_snapshot)
    create(
      :issue,
      :pull_request,
      project: project,
      title: title,
      github_number: github_number,
      github_updated_at: 2.days.ago,
      awaiting_approval_since: 2.days.ago,
      auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: snapshot
    )
  end

  def create_escalated_pr(title: "Escalated PR", github_number: 505, reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK, **attrs)
    create(
      :issue,
      :pull_request,
      project: project,
      title: title,
      github_number: github_number,
      pr_review_phase: "escalated",
      pr_escalation_reason: reason,
      labels: [ "paid-generated", "paid-automation", "paid-escalated" ],
      **attrs
    )
  end

  def create_manual_review_issue(title: "Manual review issue", github_number: 506, reason: "Round limit reached.", **attrs)
    create(
      :issue,
      project: project,
      title: title,
      github_number: github_number,
      paid_state: "manual_review",
      manual_review_reason: reason,
      **attrs
    )
  end

  def create_action_required_notification(subject: project, source: "quality_auto_resume_cooldown")
    create(
      :notification,
      :error,
      account: account,
      subject: subject,
      source: source,
      blocking: true,
      title: "Quality pause requires manual review",
      metadata: {
        "recommended_action" => "Review the quality dashboard and resume manually or adjust thresholds.",
        "remediation_steps" => [ "Open the quality dashboard", "Resume manually or adjust thresholds" ]
      }
    )
  end

  def stale_approval_snapshot
    {
      "failed" => [ {
        "signal" => "reviews_fresh",
        "status" => "failed",
        "reason_code" => "stale_approval",
        "sanitized_message" => "The owner approval is stale for the current HEAD commit.",
        "next_action" => "Ask @viamin to re-approve this pull request for the current HEAD commit."
      } ],
      "not_evaluated" => []
    }
  end

  def owner_approval_snapshot
    {
      "failed" => [ {
        "signal" => "owner_approved",
        "status" => "failed",
        "reason_code" => "owner_approval_missing",
        "sanitized_message" => "Owner approval is missing.",
        "next_action" => "Ask the owner to approve."
      } ],
      "not_evaluated" => []
    }
  end
end
