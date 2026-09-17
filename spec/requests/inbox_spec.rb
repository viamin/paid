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
  # Factory projects come with a github_token, so github_credential_present?
  # returns true and the new context_markdown accessor reaches for issue
  # comments from GitHub. Stub the client so the inbox page builds without
  # the network; tests that exercise context loading override this with a
  # richer comment fixture.
  let(:github_client) { instance_double(GithubClient, issue_comments: []) }

  before do
    sign_in user
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

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

  it "wires the shared list-detail shell's list and detail panes to the inbox master-detail targets" do
    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-005
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    document = Nokogiri::HTML(response.body)
    list = document.at_css("#inbox-list")
    detail = document.at_css("#inbox-detail-pane")

    expect(list).to be_present
    expect(list["data-inbox-master-detail-target"]).to eq("list")
    expect(detail).to be_present
    expect(detail["data-inbox-master-detail-target"]).to eq("detailSection")
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
    # @spec LIST-DETAIL-001
    issue = create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_entry_path(
      entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue),
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Back to queue", "Submit Answers", "lg:grid-cols-[22rem_minmax(0,1fr)]")
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
    expect(form["data-turbo-frame"]).to eq("_top")
    expect(form.at_css('input[name="return_to"]')["value"]).to eq(inbox_path(kind: Inbox::Queue::ESCALATED_PR_KIND))
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
    expect(form["data-turbo-frame"]).to eq("_top")
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

  # @spec OPERATOR-INBOX-012
  context "when a clarifying question carries strict choice markers" do
    let(:multi_choice_question) do
      "Which browsers must the export UI support? " \
        "- [ ] Chrome) primary browser " \
        "- [ ] Firefox) required by the support team"
    end

    def create_choice_issue
      create(
        :issue,
        :needs_input,
        project: project,
        title: "Choice question",
        body: "No markdown here",
        needs_input_questions: [ multi_choice_question, "What is the expected behavior?" ]
      )
    end

    it "renders the click-to-answer widget with checkbox pills in the inbox detail pane" do
      issue = create_choice_issue

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      widget = document.at_css("turbo-frame#inbox-detail [data-controller='clarifying-choice']")
      expect(widget).to be_present

      checkboxes = widget.css('input[type="checkbox"]')
      expect(checkboxes.size).to eq(3)
      expect(checkboxes.map { |box| box["data-clarifying-choice-line"] }.compact).to eq(
        [ "Chrome (primary browser)", "Firefox (required by the support team)" ]
      )
      expect(widget.at_css("label[for$='_other']")).to be_present

      composed = widget.at_css('input[type="hidden"][name="answers[]"]')
      expect(composed["data-testid"]).to eq("inbox-answer-0")
      expect(composed["data-clarifying-choice-target"]).to eq("composed")
    end

    it "keeps the textarea-only widget for questions without parsed choices" do
      issue = create_choice_issue

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      detail_frame = Nokogiri::HTML(response.body).at_css("turbo-frame#inbox-detail")
      textareas = detail_frame.css("textarea[name='answers[]']")

      expect(textareas.size).to eq(1)
      expect(textareas.first["data-testid"]).to eq("inbox-answer-1")
      expect(textareas.first["required"]).to be_present
    end
  end

  # @spec OPERATOR-INBOX-011
  context "when the enhancement comment carries context sections" do
    let(:context_comment_body) do
      <<~COMMENT
        <!-- paid:enhance-issue -->

        ## Clarifying questions

        Need a call before implementation.

        1. What is the expected behavior?
        2. Should this be behind a flag?

        ## Current context
        - The repo already has a flag toggle wired up.
        - Existing tests live in `app/services/foo.rb`.
      COMMENT
    end
    let(:enhancement_comment) { double(body: context_comment_body, user: double(login: "viamin")) }

    before do
      allow(github_client).to receive(:issue_comments).and_return([ enhancement_comment ])
    end

    it "renders the context panel inside a details disclosure with the preamble + Current context body wired into markdown-text" do
      issue = create(:issue, :needs_input, project: project, title: "Context question", body: questions_body)

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Context from Paid")
      panel = Nokogiri::HTML(response.body).at_css("[data-testid='inbox-clarifying-context']")
      expect(panel).to be_present
      expect(panel.at_css("summary")).to be_present

      context_node = panel.at_css('[data-controller="markdown-text"]')
      expect(context_node["data-markdown-text-block-value"]).to eq("true")
      expect(context_node["data-markdown-text-content-value"]).to include("Need a call before implementation.")
      expect(context_node["data-markdown-text-content-value"]).to include("- The repo already has a flag toggle wired up.")
    end

    it "lays the context out beside the form on lg+ viewports via a two-column grid" do
      issue = create(:issue, :needs_input, project: project, title: "Context question", body: questions_body)

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      grid = Nokogiri::HTML(response.body).at_css("[data-testid='inbox-clarifying-context']").parent
      expect(grid["class"]).to include("lg:grid")
      expect(grid["class"]).to include("lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]")
    end

    it "does not collapse the disclosure on lg+ so the operator does not have to tap to read context" do
      issue = create(:issue, :needs_input, project: project, title: "Context question", body: questions_body)

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      panel = Nokogiri::HTML(response.body).at_css("[data-testid='inbox-clarifying-context']")
      # OPERATOR-INBOX-011 expects the context to be visible by default on lg+
      # so the operator does not have to expand the disclosure before reading it.
      # The native <details open> default-expansion is what removes that tap;
      # Nokogiri represents a present boolean attribute as `""`, so we look
      # for the attribute itself rather than a truthy string value.
      expect(panel.attribute("open")).not_to be_nil
      expect(panel["class"]).to include("lg:sticky")
      expect(panel.at_css("summary")["class"]).to include("lg:cursor-default")
    end

    it "escapes the fallback text so it never renders as raw HTML before JS runs" do
      issue = create(:issue, :needs_input, project: project, title: "Context question", body: questions_body)

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      # The comment contains a markdown backtick, so the fallback should ship
      # the escaped raw string — never a live <code> tag — until the JS
      # controller replaces it. The plain-text path uses escapeHtml in
      # safe_markdown, so we look for the escaped form here.
      expect(response.body).to include(CGI.escapeHTML("Existing tests live in `app/services/foo.rb`."))
    end

    it "keeps the View Issue link alongside the submit button when context is rendered" do
      issue = create(:issue, :needs_input, project: project, title: "Context question", body: questions_body)

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      document = Nokogiri::HTML(response.body)
      view_issue = document.css("a").find { |anchor| anchor.text.include?("View") }
      submit = document.at_css(%(form[action="#{project_issue_clarifying_questions_path(project, issue)}"] input[type="submit"]))

      expect(view_issue).to be_present
      expect(view_issue["href"]).to eq(issue.github_url)
      expect(submit).to be_present
    end
  end

  # @spec OPERATOR-INBOX-011
  context "when the enhancement comment has no recoverable context" do
    let(:enhancement_comment) { double(body: questions_body, user: double(login: "viamin")) }

    before do
      allow(github_client).to receive(:issue_comments).and_return([ enhancement_comment ])
    end

    it "hides the context panel and keeps the answer form intact" do
      issue = create(:issue, :needs_input, project: project, title: "No context", body: questions_body)

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Context from Paid")
      expect(response.body).not_to include("data-testid=\"inbox-clarifying-context\"")
      # The two-column grid wrapper is only emitted when context_markdown
      # is present, so absence here is the signal that we fell back cleanly.
      expect(response.body).not_to include("lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]")
      # Existing form + View Issue link remain so the operator can still
      # answer the question and consult GitHub directly.
      expect(response.body).to include("View Issue")
      expect(response.body).to include("What is the expected behavior?")
    end
  end

  # @spec OPERATOR-INBOX-011
  context "when the questions come from the local needs_input_questions snapshot" do
    it "hides the context panel because no comment was fetchable" do
      issue = create(
        :issue,
        :needs_input,
        project: project,
        title: "Local snapshot question",
        body: "No markdown here",
        needs_input_questions: [ "What is the desired behavior?" ]
      )

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Context from Paid")
      expect(response.body).not_to include("data-testid=\"inbox-clarifying-context\"")
      expect(response.body).to include("What is the desired behavior?")
    end
  end

  # @spec OPERATOR-INBOX-011
  context "when GitHub credentials are missing" do
    it "hides the context panel and keeps the View Issue link" do
      issue = create(:issue, :needs_input, project: project, title: "Missing creds", body: questions_body)
      allow(project).to receive(:github_credential_present?).and_return(false)

      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Context from Paid")
      expect(response.body).to include("View Issue")
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
