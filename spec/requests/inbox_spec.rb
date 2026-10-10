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

  # @spec OPERATOR-INBOX-001 @spec OPERATOR-INBOX-003 @spec INBOX-FOUNDATION-009
  it "lists clarifying-question and plan-review entries across auto-pick projects" do
    review = create_inbox_entries

    get inbox_entry_path(entry_id(Inbox::Queue::PLAN_REVIEW_KIND, review))

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Inbox", project.full_name, second_project.full_name)
    expect(response.body).to include("Alpha question", "Beta question", "PR question", "Approval blocked PR", "Review me", "Quality pause requires manual review")
    expect(response.body).to include("Visible task", "What is the expected behavior?")
    expect(response.body).not_to include("Closed question")
  end

  it "renders compact URL-driven filters with the selected project, kind, and sort" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND, sort: "newest")

    document = Nokogiri::HTML(response.body)
    filter = document.at_css("[data-controller~='inbox-filters']")

    expect(filter).to be_present
    expect(document.at_css("[data-inbox-filters-target='trigger']").text).to include("Filters", project.full_name, "Clarifying Questions", "Newest first")
    expect(document.at_css("input[name='kind'][value='clarifying_questions']")["checked"]).to be_present
    expect(document.at_css("input[name='project_id'][value='#{project.id}']")["checked"]).to be_present
    expect(document.at_css("input[name='sort'][value='newest']")["checked"]).to be_present
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

  # @spec PARTIAL-CLOSEOUT-002 @spec PARTIAL-CLOSEOUT-007
  it "directs operators to make the stalled issue depend on its follow-up prerequisite" do
    issue = create(:issue, project: project, github_number: 500, paid_state: "in_progress")
    prerequisite = create(:issue, project: project, github_number: 501, github_state: "open")
    create(:issue_dependency, issue: issue, depends_on_issue: prerequisite)
    create(:issue, :pull_request, project: project, github_number: 502, github_state: "closed",
      pr_review_phase: "merged", parent_issue: issue, created_at: 2.days.ago)

    get inbox_entry_path(
      entry_id(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue),
      project_id: project.id,
      kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Depends on #B")
    expect(response.body).not_to include("Depends on #500")
  end

  # @spec PARTIAL-CLOSEOUT-022 @spec PARTIAL-CLOSEOUT-014 @spec PARTIAL-CLOSEOUT-015 @spec PARTIAL-CLOSEOUT-016
  describe "partial closeout pane guidance" do
    let(:guided_issue) { create(:issue, project: project, github_number: 510, paid_state: "in_progress") }
    let(:guided_evidence) do
      create(:issue, :pull_request, project: project, github_number: 511, github_state: "closed",
        pr_review_phase: "merged", parent_issue: guided_issue, created_at: 2.days.ago)
    end

    before do
      guided_evidence
      create(:notification, :error, account: account, subject: guided_issue,
        source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
        title: "Pilot results need operator action",
        description: "Pilot latency results: attach the measured p95 to the follow-up comment and link it here")
    end

    def render_guided_pane
      get inbox_entry_path(
        entry_id(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, guided_issue),
        project_id: project.id,
        kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND
      )

      expect(response).to have_http_status(:ok)
    end

    it "lists the decision paths and links the operator guide" do
      render_guided_pane

      expect(response.body).to include("Deciding what to do")
      expect(response.body).to include("Review the recorded evidence")
      expect(response.body).to include("Continue agent-actionable work")
      expect(response.body).to include("Link prerequisite work")
      expect(response.body).to include("Supply human evidence")
      expect(response.body).to include("attest completion")
      expect(response.body).to include(partial_closeout_guide_path)
    end

    it "collects an editable rationale and separates the three completions" do
      render_guided_pane

      expect(response.body).to include("Completion rationale")
      expect(response.body).to include("Completing a run")
      expect(response.body).to include("Resolving this Inbox item")
      expect(response.body).to include("Closing the GitHub issue")
      expect(response.body).to include("The GitHub issue stays open")
      expect(response.body).not_to match(/type="hidden"[^>]*name="reason"/)
    end

    it "explains the continuation authorization semantics with examples" do
      render_guided_pane

      expect(response.body).to include("authorizes exactly one run")
      expect(response.body).to include("Other holds still apply")
      expect(response.body).to include("expected evidence")
      expect(response.body).to include("acceptance audit")
      expect(response.body).to include("implementation gap")
      expect(response.body).to include("scanner verification")
      expect(response.body).to include("human-only evaluation")
    end

    it "surfaces the requested human evidence and resumption rules" do
      render_guided_pane

      expect(response.body).to include("Pilot latency results")
      expect(response.body).to include("who must supply it")
      expect(response.body).to include("resumes automatically")
      expect(response.body).to include("deliberate continuation")
    end

    # @spec PARTIAL-CLOSEOUT-023
    it "shows stale criterion evidence and prevents a duplicate run on an open owner on narrow layouts" do
      owner = create(:issue, project:, github_state: "open", github_number: 512)
      run = create(:agent_run, :completed, project:, issue: guided_issue, pull_request_number: guided_evidence.github_number)
      run.update!(reconciliation: {
        "assessment" => {
          "source_revision" => "superseded", "intent_revision" => "superseded", "assessed_at" => 2.days.ago.iso8601,
          "classification" => "blocked_implementation",
          "criteria" => [ { "criterion" => "Pilot p95", "state" => "unknown", "owner_issue_number" => owner.github_number,
            "prerequisite_kind" => "human", "prerequisite" => "Attach the production p95." } ],
          "next_action" => { "kind" => "wait_for_owner", "explanation" => "Open work already owns this." }
        }
      })

      render_guided_pane

      expect(response.body).to include("Acceptance assessment", "This assessment is stale", "Pilot p95", "unknown")
      expect(response.body).to include("Owner: #512 (open)", "Human prerequisite", "request a bounded acceptance audit")
      expect(response.body).to include("flex-col", "sm:flex-row")
    end

    # @spec PARTIAL-CLOSEOUT-023 — legacy gaps-only assessments never had
    # `source_revision` / `intent_revision` recorded, so every legacy row
    # is stale on the digest mismatch alone — but nothing actually changed.
    # The pane must distinguish that "nothing recorded" state from a real
    # revision change so operators get actionable copy instead of the
    # contradictory "is stale because the approved intent or closeout
    # evidence changed" message right after deploy (#4208 review).
    it "calls out stale-without-revision-metadata separately from a real revision change" do
      run = create(:agent_run, :completed, project:, issue: guided_issue, pull_request_number: guided_evidence.github_number)
      run.update!(reconciliation: {
        "assessment" => { "gaps" => [ { "criterion" => "Legacy gap", "kind" => "agent", "title" => "Ship it" } ] }
      })

      render_guided_pane

      expect(response.body).to include("No criterion-level assessment with revision metadata is recorded")
      expect(response.body).not_to include("This assessment is stale because the approved intent or closeout evidence changed")
    end

    it "offers the link-prerequisite action with its sync explanation" do
      render_guided_pane

      expect(response.body).to include("Link a prerequisite")
      expect(response.body).to include(link_prerequisite_project_agent_runs_path(project))
      expect(response.body).to include("sync")
    end

    it "offers the link-prerequisite action before any prerequisite exists" do
      issue = create(:issue, project: project, github_number: 512, paid_state: "in_progress")
      create(:issue, :pull_request, project: project, github_number: 513, github_state: "closed",
        pr_review_phase: "merged", parent_issue: issue)

      get inbox_entry_path(
        entry_id(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue),
        project_id: project.id,
        kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND
      )

      expect(response.body).to include("Link a prerequisite")
      expect(response.body).to include(link_prerequisite_project_agent_runs_path(project))
    end
  end

  # @spec CHANGE-INTENT-INBOX-001
  it "renders change_intent_draft entries with approve, request changes, discard, and chat actions" do
    change_intent = create(
      :change_intent, :draft, :without_context_links, project: project,
      title: "Sliding window over token bucket",
      intent: "Smooth per-user limiting.",
      behavior: nil,
      constraints: "Use Redis.",
      decisions_made: "Rejected token bucket."
    )

    get inbox_entry_path(
      entry_id(Inbox::Queue::CHANGE_INTENT_DRAFT_KIND, change_intent),
      kind: Inbox::Queue::CHANGE_INTENT_DRAFT_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("CIR Drafts", "Sliding window over token bucket")
    expect(response.body).to include("Approve", "Request changes on this draft", "Discard", "Chat about this")
    expect(response.body).to include(approve_project_change_intent_path(project, change_intent))
    expect(response.body).to include(discard_project_change_intent_path(project, change_intent))
    expect(response.body).to include(request_changes_project_change_intent_path(project, change_intent))
  end

  # @spec CHANGE-INTENT-INBOX-001
  it "renders the requested_changes reason and badge for a re-reviewed draft" do
    change_intent_issue = create(:issue, project: project, github_number: 88, title: "Source issue")
    change_intent = create(
      :change_intent, :draft, project: project, issue: change_intent_issue,
      title: "Sliding window over token bucket",
      intent: "Smooth per-user limiting.",
      constraints: "Use Redis."
    )
    change_intent.update!(status: "requested_changes",
      requested_changes_at: 1.hour.ago,
      requested_changes_reason: "Reword the title.")

    get inbox_entry_path(
      entry_id(Inbox::Queue::CHANGE_INTENT_DRAFT_KIND, change_intent),
      kind: Inbox::Queue::CHANGE_INTENT_DRAFT_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Changes requested", "Reword the title.")
    expect(response.body).not_to include(discard_project_change_intent_path(project, change_intent))
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

  it "opens the current user's canonical interactive chat for an inbox entry" do
    # @spec QUESTION-EXPLORATION-001 @spec QUESTION-EXPLORATION-014
    issue = create(:issue, :needs_input, project:, title: "Alpha question", body: questions_body)

    post inbox_interactive_chat_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue)),
      as: :json

    expect(response).to have_http_status(:created)
    expect(ChatSession.last).to have_attributes(created_by: user, inbox_item_key: "clarifying_questions:#{issue.id}")
  end

  # @spec OPERATOR-INBOX-002F
  it "opens the retry-limited investigation chat through the Inbox route" do
    issue = create_retry_limited_issue(title: "Capped issue", github_number: 4632)

    post inbox_interactive_chat_path(entry_id(Inbox::Queue::RETRY_LIMITED_KIND, issue)), as: :json

    expect(response).to have_http_status(:created)
    expect(ChatSession.last).to have_attributes(
      inbox_item_key: "retry_limited:#{issue.id}",
      title: "#{project.full_name}#4632: retry exhaustion chat"
    )
    expect(ChatSession.last.inbox_item_metadata).to include("issue_id" => issue.id)
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
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      sort: "newest"
    )

    expect(response).to redirect_to(
      inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND, sort: "newest")
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

  # @spec INTENT-CONFORMANCE-006
  it "renders intent-conformance detail with the cited claim, diff, evidence, and resolution actions" do
    pr = create_intent_conformance_pr(title: "Drifted PR")

    get inbox_entry_path(
      entry_id(Inbox::Queue::INTENT_CONFORMANCE_KIND, pr),
      project_id: project.id,
      kind: Inbox::Queue::INTENT_CONFORMANCE_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Approved-intent conformance is blocking auto-merge")
    expect(response.body).to include("Bounded exceptions are head-scoped.")
    expect(response.body).to include("app/services/intent_conformance/signal.rb")
    expect(response.body).to include("The PR changes the approved retry policy.")
    expect(response.body).to include("Require the agent to bring the PR back within scope")
    expect(response.body).to include("Approve a bounded exception for this exact PR HEAD")
    expect(response.body).to include("Open a design amendment")
  end

  # @spec INTENT-CONFORMANCE-003 @spec INTENT-CONFORMANCE-006
  it "omits the resolution form when no verdict exists for the current HEAD" do
    pr = create_intent_conformance_pr(title: "Unscored PR", verdict: nil)

    get inbox_entry_path(
      entry_id(Inbox::Queue::INTENT_CONFORMANCE_KIND, pr),
      project_id: project.id,
      kind: Inbox::Queue::INTENT_CONFORMANCE_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Approved-intent conformance is blocking auto-merge")
    expect(response.body).to include("could not evaluate this pull request")
    expect(response.body).not_to include("Resolve this decision")
    expect(response.body).not_to include("Require the agent to bring the PR back within scope")
  end

  # @spec OPERATOR-INBOX-002C @spec INBOX-FOUNDATION-006
  it "lists escalated pull requests regardless of auto-pick enablement but not from other accounts' projects" do
    auto_pick_off_project = create(:project, account: account, created_by: user, auto_pick_enabled: false, active: true)
    other_user = create(:user, account: create(:account))
    other_account_project = create(:project, account: other_user.account, created_by: other_user, active: true)
    create_escalated_pr(title: "Escalated PR", github_number: 500)
    create_escalated_pr(title: "Auto-pick off PR", github_number: 501, project: auto_pick_off_project)
    create_escalated_pr(title: "Other account PR", github_number: 502, project: other_account_project)

    get inbox_path(kind: Inbox::Queue::ESCALATED_PR_KIND)

    expect(response.body).to include("Blocked PRs", "Escalated PR", "Auto-pick off PR")
    expect(response.body).not_to include("Other account PR")
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

  # @spec OPERATOR-INBOX-002D @spec INBOX-FOUNDATION-006
  it "lists manual_review issues regardless of auto-pick enablement but not from other accounts' projects" do
    auto_pick_off_project = create(:project, account: account, created_by: user, auto_pick_enabled: false, active: true)
    other_user = create(:user, account: create(:account))
    other_account_project = create(:project, account: other_user.account, created_by: other_user, active: true)
    create_manual_review_issue(title: "Parked issue", github_number: 507)
    create_manual_review_issue(title: "Auto-pick off issue", github_number: 508, project: auto_pick_off_project)
    create_manual_review_issue(title: "Other account issue", github_number: 509, project: other_account_project)

    get inbox_path(kind: Inbox::Queue::MANUAL_REVIEW_KIND)

    expect(response.body).to include("Manual Review", "Parked issue", "Auto-pick off issue")
    expect(response.body).not_to include("Other account issue")
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

  # @spec OPERATOR-INBOX-002D @spec ISSUE-ENHANCEMENT-011
  it "renders the clarifying-questions answer form for a manual_review issue with preserved terminal-round questions" do
    parked = create_manual_review_issue(
      title: "Parked with questions",
      github_number: 510,
      reason: "Paid has reached the configured limit of 3 enhancement re-evaluation rounds for this issue.",
      needs_input_questions: [ "Which events should be recorded?" ]
    )

    get inbox_entry_path(
      entry_id(Inbox::Queue::MANUAL_REVIEW_KIND, parked),
      kind: Inbox::Queue::MANUAL_REVIEW_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Which events should be recorded?", "Submit Answers", "Start enhancement run")
    document = Nokogiri::HTML(response.body)
    form = document.at_css(%(form[action="#{project_issue_clarifying_questions_path(project, parked)}"]))

    expect(form).to be_present
    expect(form.at_css('input[name="inbox"]')["value"]).to eq("1")
  end

  # @spec OPERATOR-INBOX-002D @spec ISSUE-ENHANCEMENT-011
  # Questions are preserved on every manual_review stop path
  # (IssueEnhancements::StopForManualReview), including the hard parse-failure
  # stop — so the banner must not assert a stop cause the condition cannot
  # distinguish; the cause lives in the "Why this is in your inbox" summary.
  it "renders the answer form without asserting a round-limit cause for a parse-failure stop with preserved questions" do
    parked = create_manual_review_issue(
      title: "Parked by parse failure",
      github_number: 511,
      reason: "Paid could not validate the enhancement agent's structured output.",
      needs_input_questions: [ "Which events should be recorded?" ]
    )

    get inbox_entry_path(
      entry_id(Inbox::Queue::MANUAL_REVIEW_KIND, parked),
      kind: Inbox::Queue::MANUAL_REVIEW_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      "Paid could not validate the enhancement agent",
      "Which events should be recorded?",
      "Answer them below to resume"
    )
    expect(response.body).not_to include("enhancement round limit")
  end

  # @spec OPERATOR-INBOX-002E @spec INBOX-FOUNDATION-006
  it "lists retry-limited issues regardless of auto-pick enablement but not from other accounts' projects" do
    auto_pick_off_project = create(:project, account: account, created_by: user, auto_pick_enabled: false, active: true, owner: "acme", repo: "epsilon")
    other_user = create(:user, account: create(:account))
    other_account_project = create(:project, account: other_user.account, created_by: other_user, active: true, owner: "acme", repo: "zeta")
    create_retry_limited_issue(title: "Capped issue", github_number: 510)
    create_retry_limited_issue(title: "Auto-pick off issue", github_number: 511, project: auto_pick_off_project)
    create_retry_limited_issue(title: "Other account issue", github_number: 512, project: other_account_project)

    get inbox_path(kind: Inbox::Queue::RETRY_LIMITED_KIND)

    expect(response.body).to include("Retry-limited", "Capped issue", "Auto-pick off issue")
    expect(response.body).not_to include("Other account issue")
  end

  # @spec OPERATOR-INBOX-002E
  it "distinguishes Push Blocked from Retry Cap in the list view badge" do
    capped = create_retry_limited_issue(title: "Capped issue", github_number: 512)
    push_blocked = create(
      :issue,
      project: project,
      title: "Push blocked issue",
      github_number: 513,
      runner_retry_abandoned_at: 1.hour.ago,
      runner_retry_abandon_reason: "#{Issue::PUSH_PERMISSION_ABANDON_PREFIX} missing workflows permission"
    )

    get inbox_path(kind: Inbox::Queue::RETRY_LIMITED_KIND)

    document = Nokogiri::HTML(response.body)
    capped_row = document.at_xpath(%(//li[.//p[contains(text(), "#{capped.title}")]]))
    push_blocked_row = document.at_xpath(%(//li[.//p[contains(text(), "#{push_blocked.title}")]]))

    expect(capped_row.text).to include("Retry Cap")
    expect(capped_row.text).not_to include("Push Blocked")
    expect(push_blocked_row.text).to include("Push Blocked")
    expect(push_blocked_row.text).not_to include("Retry Cap")
  end

  # @spec OPERATOR-INBOX-002F
  it "shows the retry return count in the list and detail views" do
    capped = create_retry_limited_issue(title: "Capped issue", github_number: 518, runner_retry_abandonment_count: 3)

    get inbox_path(kind: Inbox::Queue::RETRY_LIMITED_KIND)

    expect(response.body).to include("×2 returns")

    get inbox_entry_path(entry_id(Inbox::Queue::RETRY_LIMITED_KIND, capped), kind: Inbox::Queue::RETRY_LIMITED_KIND)

    expect(response.body).to include("×2 returns")
  end

  # @spec OPERATOR-INBOX-002F
  it "hides the retry return badge for a first-time abandonment" do
    first_timer = create_retry_limited_issue(title: "First cap", github_number: 520, runner_retry_abandonment_count: 1)

    get inbox_path(kind: Inbox::Queue::RETRY_LIMITED_KIND)

    expect(response.body).not_to include("×1 returns")

    get inbox_entry_path(entry_id(Inbox::Queue::RETRY_LIMITED_KIND, first_timer), kind: Inbox::Queue::RETRY_LIMITED_KIND)

    expect(response.body).not_to include("×1 returns")
  end

  # @spec OPERATOR-INBOX-002E
  it "renders the retry_limited detail with the abandon reason and the Retry Cap badge for runner-cap abandonments" do
    capped = create_retry_limited_issue(
      title: "Capped issue",
      github_number: 512,
      reason: "All available runners reached the per-issue retry cap (3) after repeated failures and were excluded: claude, codex."
    )

    get inbox_entry_path(
      entry_id(Inbox::Queue::RETRY_LIMITED_KIND, capped),
      kind: Inbox::Queue::RETRY_LIMITED_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("All available runners reached the per-issue retry cap (3)")
    expect(response.body).to include("Retry Cap")
    expect(response.body).not_to include("Push Blocked")
  end

  # @spec OPERATOR-INBOX-002E
  it "renders the Push Blocked badge and reason when a retry-limited issue was abandoned by push permission" do
    push_blocked = create(
      :issue,
      project: project,
      title: "Push blocked issue",
      github_number: 513,
      runner_retry_abandoned_at: 1.hour.ago,
      runner_retry_abandon_reason: "#{Issue::PUSH_PERMISSION_ABANDON_PREFIX} missing workflows permission"
    )

    get inbox_entry_path(
      entry_id(Inbox::Queue::RETRY_LIMITED_KIND, push_blocked),
      kind: Inbox::Queue::RETRY_LIMITED_KIND
    )

    expect(response.body).to include("Push Blocked")
    expect(response.body).to include("missing workflows permission")
  end

  # @spec OPERATOR-INBOX-002E
  it "renders the retry_limited detail with an inbox-scoped Re-enable action and return_to for runner-cap abandonments" do
    capped = create_retry_limited_issue(
      title: "Capped issue", github_number: 514,
      reason: "All available runners reached the per-issue retry cap (3)."
    )

    get inbox_entry_path(entry_id(Inbox::Queue::RETRY_LIMITED_KIND, capped), kind: Inbox::Queue::RETRY_LIMITED_KIND)

    form = Nokogiri::HTML(response.body).at_css(
      %(form[action="#{clear_retry_abandonment_project_agent_runs_path(project, issue_id: capped.id)}"])
    )

    expect(form).to be_present
    expect(form["data-turbo-frame"]).to eq("_top")
    expect(form["data-turbo-confirm"]).to include("retry-cap flag").and include("queue a run from the project page")
    expect(form.at_css('button').text).to include("Re-enable")
    expect(form.at_css('input[name="return_to"]')["value"]).to eq(inbox_path(kind: Inbox::Queue::RETRY_LIMITED_KIND))
  end

  # @spec OPERATOR-INBOX-002F
  it "renders an authorized Investigate in chat button for retry-limited entries" do
    capped = create_retry_limited_issue(title: "Capped issue", github_number: 519)

    get inbox_entry_path(entry_id(Inbox::Queue::RETRY_LIMITED_KIND, capped), kind: Inbox::Queue::RETRY_LIMITED_KIND)

    form = Nokogiri::HTML(response.body).at_css(
      %(form[action="#{inbox_interactive_chat_path(entry_id(Inbox::Queue::RETRY_LIMITED_KIND, capped))}"])
    )

    expect(form).to be_present
    expect(form.at_css("button").text).to include("Investigate in chat")
  end

  # @spec OPERATOR-INBOX-002E
  it "renders the retry_limited detail with the inbox-scoped Re-enable action for Push Blocked abandonments" do
    push_blocked = create(
      :issue, project: project, title: "Push blocked issue", github_number: 515,
      runner_retry_abandoned_at: 1.hour.ago,
      runner_retry_abandon_reason: "#{Issue::PUSH_PERMISSION_ABANDON_PREFIX} missing workflows permission"
    )

    get inbox_entry_path(entry_id(Inbox::Queue::RETRY_LIMITED_KIND, push_blocked), kind: Inbox::Queue::RETRY_LIMITED_KIND)

    form = Nokogiri::HTML(response.body).at_css(
      %(form[action="#{clear_retry_abandonment_project_agent_runs_path(project, issue_id: push_blocked.id)}"])
    )

    expect(form).to be_present
    expect(form["data-turbo-frame"]).to eq("_top")
    expect(form["data-turbo-confirm"]).to include("push-block flag")
    expect(form["data-turbo-confirm"]).not_to include("queue a run from the project page")
    expect(form.at_css('button').text).to include("Re-enable")
  end

  # @spec OPERATOR-INBOX-002E
  it "renders the retry_limited 'Open project runs' link with turbo_frame=_top so it navigates out of the inbox-detail frame" do
    capped = create_retry_limited_issue(title: "Capped issue", github_number: 516)

    get inbox_entry_path(
      entry_id(Inbox::Queue::RETRY_LIMITED_KIND, capped),
      kind: Inbox::Queue::RETRY_LIMITED_KIND
    )

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    link = document.at_css(%(a[href="#{project_agent_runs_path(project)}"]))

    expect(link).to be_present
    expect(link.text).to eq("Open project runs")
    expect(link["data-turbo-frame"]).to eq("_top")
  end

  # @spec OPERATOR-INBOX-002E
  it "exposes retry_limited in the inbox filter panel" do
    get inbox_path

    document = Nokogiri::HTML(response.body)
    control = document.at_css("input[name='kind'][value='#{Inbox::Queue::RETRY_LIMITED_KIND}']")

    expect(control).to be_present
  end

  # @spec OPERATOR-INBOX-002E
  it "accepts retry_limited as a valid inbox kind for the nav filter" do
    get inbox_path(kind: Inbox::Queue::RETRY_LIMITED_KIND)

    expect(response).to have_http_status(:ok)
  end

  # @spec OPERATOR-INBOX-002D
  it "exposes manual_review in the inbox filter panel and filters to it" do
    create_manual_review_issue(title: "Parked issue", github_number: 514)

    get inbox_path

    document = Nokogiri::HTML(response.body)
    control = document.at_css("input[name='kind'][value='#{Inbox::Queue::MANUAL_REVIEW_KIND}']")
    expect(control).to be_present

    get inbox_path(kind: Inbox::Queue::MANUAL_REVIEW_KIND)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Parked issue")
  end

  # @spec FEATURE-APPROVAL-013
  it "exposes feature_decision in the inbox filter panel and filters to it" do
    feature_intent = create(:feature_intent, :ready_for_approval, project: project, title: "Bulk CSV export")

    get inbox_path

    document = Nokogiri::HTML(response.body)
    control = document.at_css("input[name='kind'][value='#{Inbox::Queue::FEATURE_DECISION_KIND}']")
    expect(control).to be_present

    get inbox_path(kind: Inbox::Queue::FEATURE_DECISION_KIND)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(feature_intent.title)
  end

  # @spec INTENT-CONFORMANCE-006
  it "exposes intent_conformance in the inbox filter panel and filters to it" do
    pr = create_intent_conformance_pr(title: "Drifted PR")

    get inbox_path

    document = Nokogiri::HTML(response.body)
    control = document.at_css("input[name='kind'][value='#{Inbox::Queue::INTENT_CONFORMANCE_KIND}']")
    expect(control).to be_present

    get inbox_path(kind: Inbox::Queue::INTENT_CONFORMANCE_KIND)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(pr.title)
  end

  it "lists every lane kind in the empty-state copy" do
    get inbox_path

    expect(response.body).to include("Inbox clear")
    expect(response.body).to include(
      "clarifying-question", "plan-review", "merge-approval", "action-required",
      "blocked-PR", "manual-review", "intent-conformance", "feature-decision", "retry-limited",
      "test-review"
    )
  end

  # @spec OPERATOR-INBOX-002J
  it "exposes test_review_pending in the inbox filters dialog and filters to it" do
    pr = create_tdd_test_review_pr(title: "Red-phase tests for CSV export", github_number: 517)

    get inbox_path

    document = Nokogiri::HTML(response.body)
    option = document.at_css("input[name='kind'][value='#{Inbox::Queue::TEST_REVIEW_PENDING_KIND}']")
    expect(option).to be_present

    get inbox_path(kind: Inbox::Queue::TEST_REVIEW_PENDING_KIND)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(pr.title)
  end

  # @spec OPERATOR-INBOX-002J
  it "links the test_review_pending detail pane to the pull request" do
    pr = create_tdd_test_review_pr(title: "Red-phase tests for CSV export", github_number: 518)

    get inbox_entry_path(
      entry_id(Inbox::Queue::TEST_REVIEW_PENDING_KIND, pr),
      kind: Inbox::Queue::TEST_REVIEW_PENDING_KIND
    )

    document = Nokogiri::HTML(response.body)
    pr_link = document.at_css(%(a[href="#{pr.github_url}"]))

    expect(pr_link).to be_present
    expect(pr_link.text).to include("View")
  end

  # @spec OPERATOR-INBOX-002D
  it "links the manual_review detail pane to the GitHub issue" do
    parked = create_manual_review_issue(title: "Parked issue", github_number: 515)

    get inbox_entry_path(
      entry_id(Inbox::Queue::MANUAL_REVIEW_KIND, parked),
      kind: Inbox::Queue::MANUAL_REVIEW_KIND
    )

    document = Nokogiri::HTML(response.body)
    issue_link = document.at_css(%(a[href="#{parked.github_url}"]))

    expect(issue_link).to be_present
    expect(issue_link.text).to include("View")
  end

  # @spec OPERATOR-INBOX-002D
  it "links the manual_review detail pane to the enhancement comment when it can be resolved" do
    parked = create_manual_review_issue(title: "Parked issue", github_number: 516)
    comment_url = "#{parked.github_url}#issuecomment-1"
    allow(Inbox::ManualReviewCommentLink).to receive(:call).and_return(comment_url)

    get inbox_entry_path(
      entry_id(Inbox::Queue::MANUAL_REVIEW_KIND, parked),
      kind: Inbox::Queue::MANUAL_REVIEW_KIND
    )

    document = Nokogiri::HTML(response.body)
    comment_link = document.at_css(%(a[href="#{comment_url}"]))

    expect(comment_link).to be_present
    expect(comment_link.text).to eq("View enhancement comment")
  end

  # @spec OPERATOR-INBOX-002D @spec PARTIAL-CLOSEOUT-012
  it "surfaces the scanner alert, evidence, and recovery action when a code-scanning recurrence moved the issue to manual_review" do
    scanner_issue = create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      github_number: 200_001_838, github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 1838,
      github_state: "open")
    merged_pr = create(:issue, :pull_request, project: project, github_number: 4034,
      github_state: "closed", pr_review_phase: "merged", parent_issue: scanner_issue)
    attempt = create(:code_scanning_remediation_attempt, issue: scanner_issue,
      status: "awaiting_verification", pull_request_number: merged_pr.github_number)
    SecurityAlerts::VerifyRemediationAttempt.new(
      attempt: attempt, alert: { number: 1838, state: "open" },
      analysis: { id: "1842809913", status: "succeeded", ref: scanner_issue.project.default_branch,
        commit_sha: "descendant", tool_name: attempt.tool_name, category: attempt.category, error: "", warning: "" },
      contains_merge_commit: true
    ).call

    get inbox_entry_path(
      entry_id(Inbox::Queue::MANUAL_REVIEW_KIND, scanner_issue.reload),
      kind: Inbox::Queue::MANUAL_REVIEW_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("scanner-confirmed recurrence", "Next step:", "Evidence:")
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

  def create_intent_conformance_pr(title: "Drifted PR", github_number: 507, verdict: :material_drift)
    issue = create(
      :issue,
      :pull_request,
      project: project,
      title: title,
      github_number: github_number,
      last_scanned_head_sha: "sha1",
      auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: {
        "failed" => [ {
          "signal" => "intent_conformance_ok",
          "status" => "failed",
          "reason_code" => "intent_conformance_blocked",
          "sanitized_message" => "This pull request's conformance with the approved design has not been confirmed.",
          "next_action" => "Review the intent-conformance decision in the Inbox."
        } ],
        "not_evaluated" => []
      }
    )
    return issue if verdict.nil?

    create(
      :intent_conformance_verdict,
      verdict,
      issue: issue,
      pr_head_sha: "sha1",
      reasoning_summary: "The PR changes the approved retry policy."
    )
    issue
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

  # A draft PR parked at the TDD red-phase gate (OPERATOR-INBOX-002J).
  def create_tdd_test_review_pr(title: "TDD test review PR", github_number: 519, pr_review_phase: "draft", **attrs)
    create(
      :issue,
      :pull_request,
      project: project,
      title: title,
      github_number: github_number,
      pr_review_phase: pr_review_phase,
      labels: [ "paid-generated", "paid-automation", Inbox::Queue::TDD_TESTS_READY_FOR_REVIEW_LABEL ],
      **attrs
    )
  end

  def create_retry_limited_issue(title: "Retry-limited issue", github_number: 510, reason: "All available runners reached the per-issue retry cap (3).", **attrs)
    create(
      :issue,
      project: project,
      title: title,
      github_number: github_number,
      runner_retry_abandoned_at: 1.hour.ago,
      runner_retry_abandon_reason: reason,
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
