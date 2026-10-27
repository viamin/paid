# frozen_string_literal: true

require "rails_helper"
require "digest"
require "ostruct"

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
    allow(github_client).to receive_messages(
      ref: OpenStruct.new(object: OpenStruct.new(sha: "abc123")), commit: OpenStruct.new(sha: "abc123")
    )
  end

  def entry_id(entry_kind, record)
    "#{entry_kind}:#{record.id}"
  end

  # @spec OPERATOR-INBOX-017
  it "renders selected context in the detail response without a nested Turbo request" do
    issue = create(:issue, :needs_input, project: project, body: questions_body)
    expect(github_client).to receive(:issue_comments).once.and_return([])

    get inbox_entry_path(entry_id("clarifying_questions", issue)), headers: { "Turbo-Frame" => "inbox-detail" }

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("turbo-frame#inbox-supplement")).to be_nil
    expect(document.at_css("textarea[data-testid='inbox-answer-0']")).to be_present
  end

  # @spec OPERATOR-INBOX-015
  it "loads only the selected detail without querying unrelated lanes or rendering the queue" do
    issue = create(:issue, :needs_input, project: project, title: "Selected question", body: questions_body)
    create(:issue, :needs_input, project: project, title: "Other question", body: questions_body)
    queries = []
    subscriber = ->(*args) { queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue)),
        headers: { "Turbo-Frame" => "inbox-detail" }
    end
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="inbox-detail"', "Selected question")
    expect(response.body).not_to include("Other question", "Filters and sort", 'id="inbox-list"')
    expect(queries.grep(/FROM "(?:decomposition_decisions|feature_intents|change_intents|issue_continuation_requests)"/)).to be_empty
  end

  # @spec OPERATOR-INBOX-015
  it "rejects a detail frame selection excluded by the kind filter" do
    issue = create(:issue, :needs_input, project: project, body: questions_body)

    get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue), kind: "plan_review"),
      headers: { "Turbo-Frame" => "inbox-detail" }

    expect(response).to redirect_to(inbox_path(kind: "plan_review"))
  end

  # @spec OPERATOR-INBOX-015 @spec OPERATOR-INBOX-017
  it "does not expose another owner's entry in detail or supplementary frames" do
    hidden_project = create(:project, account: account, created_by: create(:user, account: account))
    hidden_issue = create(:issue, :needs_input, project: hidden_project, body: questions_body)
    key = entry_id("clarifying_questions", hidden_issue)
    expect(github_client).not_to receive(:issue_comments)

    get inbox_entry_path(key), headers: { "Turbo-Frame" => "inbox-detail" }
    expect(response).to redirect_to(inbox_path)

    get inbox_entry_supplement_path(key), headers: { "Turbo-Frame" => "inbox-supplement" }
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css("turbo-frame#inbox-supplement").text.strip).to be_empty
  end

  # @spec OPERATOR-INBOX-015
  it "honors the project filter on selected detail requests" do
    issue = create(:issue, :needs_input, project: project, body: questions_body)

    get inbox_entry_path(entry_id("clarifying_questions", issue), project_id: second_project.id),
      headers: { "Turbo-Frame" => "inbox-detail" }

    expect(response).to redirect_to(inbox_path(project_id: second_project.id))
  end

  # @spec OPERATOR-INBOX-015
  it "redirects malformed and resolved detail selections" do
    issue = create(:issue, :needs_input, project: project, body: questions_body, github_state: "closed")
    [ "clarifying_questions:invalid", "invalid:#{issue.id}", "clarifying_questions:#{issue.id}" ].each do |key|
      get inbox_entry_path(key), headers: { "Turbo-Frame" => "inbox-detail" }
      expect(response).to redirect_to(inbox_path)
    end
  end

  # @spec OPERATOR-INBOX-015
  it "promotes a stale detail redirect to a full-page visit even when the inbox is empty" do
    issue = create(:issue, :needs_input, project: project, body: questions_body, github_state: "closed")

    get inbox_entry_path(entry_id("clarifying_questions", issue)), headers: { "Turbo-Frame" => "inbox-detail" }
    follow_redirect!(headers: { "Turbo-Frame" => "inbox-detail" })

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Inbox clear")
    expect(Nokogiri::HTML(response.body).at_css('meta[name="turbo-visit-control"]')&.[]("content")).to eq("reload")
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

  # @spec NOTIFICATION-SEVERITY-009 OPERATOR-INBOX-002B
  it "renders action_required detail with its notification description and remediation steps" do
    notification = create_action_required_notification

    get inbox_entry_path(
      entry_id(Inbox::Queue::ACTION_REQUIRED_KIND, notification),
      kind: Inbox::Queue::ACTION_REQUIRED_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Action Required", "Quality pause requires manual review")
    expect(response.body).to include("The quality pause could not be automatically resumed.")
    expect(response.body).to include("Review the quality dashboard and resume manually or adjust thresholds.")
    expect(response.body).to include("Open the quality dashboard", "Resume manually or adjust thresholds")
  end

  # @spec OPERATOR-INBOX-002B
  it "renders a blocking notification description when remediation guidance is absent" do
    notification = create(
      :notification,
      :error,
      account: account,
      subject: project,
      source: "automation_review_method_unavailable",
      blocking: true,
      title: "Automated review could not complete",
      description: "The configured review method could not complete its check.",
      metadata: {}
    )

    get inbox_entry_path(
      entry_id(Inbox::Queue::ACTION_REQUIRED_KIND, notification),
      kind: Inbox::Queue::ACTION_REQUIRED_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("The configured review method could not complete its check.")
    expect(response.body).not_to include("A human action is required before work can continue.")
  end

  # @spec OPERATOR-INBOX-002L FACET-CONFIDENCE-022
  it "routes a typed closeout-evaluation escalation into the plain-language evaluation workflow" do
    issue = create(:issue, project: project, github_number: 4323, paid_state: "in_progress")
    create(:issue, :pull_request, project: project, github_number: 4324, github_state: "closed",
      pr_review_phase: "merged", parent_issue: issue, created_at: 2.days.ago)
    notification = create(
      :notification,
      :error,
      account: account,
      subject: issue,
      source: "facet_confidence.closeout_escalation",
      blocking: true,
      title: "Remediation Required — Independent maintainers have entered and frozen the blinded reference judgments for the facet-confidence corpus.",
      description: "Independent maintainers have entered and frozen the blinded reference judgments for the facet-confidence corpus.",
      metadata: { "inbox_action" => "facet_confidence_closeout_evaluation" }
    )
    entry = entry_id(Inbox::Queue::ACTION_REQUIRED_KIND, notification)

    get inbox_entry_path(entry, project_id: project.id, kind: Inbox::Queue::ACTION_REQUIRED_KIND)

    start_path = new_project_facet_confidence_evaluation_path(project, issue_id: issue.id,
      inbox_entry_id: entry, inbox_kind: Inbox::Queue::ACTION_REQUIRED_KIND)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Evaluation needed before this closeout can finish", "Start evaluation", start_path.gsub("&", "&amp;"))
    expect(response.body).to include("0 judgments recorded", "judgments remaining")
    expect(response.body).not_to include("blinded reference judgments", "facet-confidence corpus")

    post project_facet_confidence_evaluations_path(project), params: {
      issue_id: issue.id,
      inbox_entry_id: entry,
      inbox_kind: Inbox::Queue::ACTION_REQUIRED_KIND
    }
    evaluation = issue.facet_confidence_evaluations.find_by!(issue_id: issue.id)
    expect(response).to redirect_to(project_facet_confidence_evaluation_path(project, evaluation,
      inbox_entry_id: entry, inbox_kind: Inbox::Queue::ACTION_REQUIRED_KIND))

    get inbox_entry_path(entry, project_id: project.id, kind: Inbox::Queue::ACTION_REQUIRED_KIND)

    expect(response.body).to include("Continue judging", "0 judgments recorded (0 of #{evaluation.progress[:total]})")
  end

  # @spec OPERATOR-INBOX-002B
  # Regression for #4501: internal GET links inside the inbox-detail frame
  # navigate the frame unless they opt out, and no target page carries a
  # matching "inbox-detail" frame — Turbo then replaces the pane with
  # "Content missing". The action links must target the full page.
  it "renders the action_required 'Open linked action' link with turbo_frame=_top so it navigates out of the inbox-detail frame" do
    notification = create_action_required_notification
    notification.update!(action_url: project_path(project))

    get inbox_entry_path(
      entry_id(Inbox::Queue::ACTION_REQUIRED_KIND, notification),
      kind: Inbox::Queue::ACTION_REQUIRED_KIND
    )

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    link = document.at_css(%(a[href="#{project_path(project)}"]))

    expect(link).to be_present
    expect(link.text).to eq("Open linked action")
    expect(link["data-turbo-frame"]).to eq("_top")
  end

  # @spec OPERATOR-INBOX-002B
  # Regression for #4501: both "View Agent Run" branches (alongside an action
  # URL, and as the sole action) must opt out of the inbox-detail frame.
  it "renders every action_required 'View Agent Run' link with turbo_frame=_top so it navigates out of the inbox-detail frame" do
    run = create(:agent_run, :failed, :with_custom_prompt, project: project)
    with_action_url = create_action_required_notification(subject: run, source: "agent_run_action_url")
    with_action_url.update!(action_url: project_path(project))
    sole_action = create_action_required_notification(subject: run, source: "agent_run_sole_action")

    [ with_action_url, sole_action ].each do |notification|
      get inbox_entry_path(
        entry_id(Inbox::Queue::ACTION_REQUIRED_KIND, notification),
        kind: Inbox::Queue::ACTION_REQUIRED_KIND
      )

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      link = document.at_css(%(a[href="#{project_agent_run_path(project, run)}"]))

      expect(link).to be_present
      expect(link.text).to eq("View Agent Run")
      expect(link["data-turbo-frame"]).to eq("_top")
    end
  end

  # @spec PROJECT-READINESS-007
  it "renders the latest failed bootstrap run with its failure reason and details link" do
    project.update!(tdd_mode: "strict", readiness_gaps: [
      { "kind" => "missing_ci", "description" => "CI is required.", "evidence" => {} }
    ])
    older_run = create(:agent_run, :failed, project:, goal: "bootstrap_readiness",
      error_message: "Older bootstrap failure", completed_at: 2.hours.ago)
    failed_run = create(:agent_run, :failed, project:, goal: "bootstrap_readiness",
      error_message: "Bootstrap write guard rejected app/models/user.rb", completed_at: 1.hour.ago)

    get inbox_entry_path(
      entry_id(Inbox::Queue::PROJECT_SETUP_PENDING_KIND, project),
      kind: Inbox::Queue::PROJECT_SETUP_PENDING_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Bootstrap run failed", failed_run.error_message)
    expect(response.body).to include(project_agent_run_path(project, failed_run))
    expect(response.body).not_to include(older_run.error_message)
  end

  # @spec PROJECT-READINESS-005 @spec PROJECT-READINESS-011
  it "describes verification-only setup gaps without attributing them to TDD" do
    project.update!(tdd_mode: "off", screenshot_settings: { "verification_enabled" => true }, readiness_gaps: [
      { "kind" => "app_start_command_unavailable", "description" => "Start the application.", "evidence" => {} }
    ])

    get inbox_entry_path(
      entry_id(Inbox::Queue::PROJECT_SETUP_PENDING_KIND, project),
      kind: Inbox::Queue::PROJECT_SETUP_PENDING_KIND
    )

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Interactive verification is enabled")
    expect(response.body).not_to include("TDD mode is enabled")
  end

  # @spec PROJECT-READINESS-005 @spec PROJECT-READINESS-011
  it "describes a verification gap correctly when TDD is also enabled" do
    project.update!(tdd_mode: "strict", screenshot_settings: { "verification_enabled" => true }, readiness_gaps: [
      { "kind" => "app_start_command_unavailable", "description" => "Start the application.", "evidence" => {} }
    ])

    get inbox_entry_path(
      entry_id(Inbox::Queue::PROJECT_SETUP_PENDING_KIND, project),
      kind: Inbox::Queue::PROJECT_SETUP_PENDING_KIND
    )

    expect(response.body).to include("Interactive verification is enabled")
    expect(response.body).not_to include("TDD mode is enabled")
  end

  # @spec PROJECT-READINESS-010
  it "targets project setup pending actions at the top-level page" do
    project.update!(tdd_mode: "strict", readiness_gaps: [
      { "kind" => "missing_ci", "description" => "CI is required.", "evidence" => {} }
    ])
    failed_run = create(:agent_run, :failed, project:, goal: "bootstrap_readiness")

    get inbox_entry_path(
      entry_id(Inbox::Queue::PROJECT_SETUP_PENDING_KIND, project),
      kind: Inbox::Queue::PROJECT_SETUP_PENDING_KIND
    ), headers: { "Turbo-Frame" => "inbox-detail" }

    document = Nokogiri::HTML(response.body)
    bootstrap_form = document.at_css(%(form[action="#{bootstrap_readiness_project_agent_runs_path(project)}"]))
    settings_link = document.at_css(%(a[href="#{edit_project_path(project)}"]))
    run_link = document.at_css(%(a[href="#{project_agent_run_path(project, failed_run)}"]))

    expect(bootstrap_form["data-turbo-frame"]).to eq("_top")
    expect(settings_link["data-turbo-frame"]).to eq("_top")
    expect(run_link["data-turbo-frame"]).to eq("_top")
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

    def create_evidence_notification
      Notification.find_by!(account: account, subject: guided_issue,
        source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE).update!(
        title: "Evidence submission", description: "Evidence submission is awaiting validation",
        metadata: {
          "prerequisites" => [
            { "identity" => "pilot-results", "criterion" => "Pilot results" },
            { "identity" => "accessibility-review", "criterion" => "Accessibility review" }
          ],
          "evidence_submissions" => [
            { "prerequisite_identity" => "pilot-results", "evidence_url" => "https://evidence.example.test/pilot",
              "explanation" => "The pilot report is attached.", "actor_id" => user.id,
              "submitted_at" => "2026-10-27T00:00:00Z", "outcome" => "pending_validation",
              "reason" => "Evidence was recorded for validation. A link alone does not satisfy acceptance." }
          ]
        })
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

    it "renders recorded evidence and unique fields for every prerequisite occurrence" do # @spec PARTIAL-CLOSEOUT-033
      create_evidence_notification
      render_guided_pane

      document = Nokogiri::HTML(response.body)
      expect(document.css("#prerequisite_pilot-results_evidence_url").size).to eq(1)
      expect(document.css("#prerequisite_accessibility-review_evidence_url").size).to eq(1)
      expect(response.body).to include("https://evidence.example.test/pilot", "The pilot report is attached.",
        "Submitted by user ##{user.id}", "pending_validation")
    end

    it "renders an evidence form for a legacy prerequisite notification" do # @spec PARTIAL-CLOSEOUT-033
      notification = Notification.find_by!(account: account, subject: guided_issue,
        source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE)
      notification.update!(metadata: {
        "prerequisite_identity" => "legacy-pilot-results",
        "references" => [ { "kind" => "artifact", "label" => "Pilot report", "revision" => "v1" } ]
      })

      render_guided_pane

      document = Nokogiri::HTML(response.body)
      expect(document.css("#prerequisite_legacy-pilot-results_evidence_url").size).to eq(1)
      expect(response.body).to include("Submit for validation")
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

    # @spec PARTIAL-CLOSEOUT-032
    it "shows the latest unavailable prerequisite validation action and retry control" do
      source_run = create(:agent_run, :completed, project:, issue: guided_issue, base_commit_sha: "a" * 40)
      source_run.update!(reconciliation: {
        "technical_prerequisite_evidence" => {
          "recorded_at" => 1.minute.ago.iso8601,
          "status" => "unavailable",
          "setup_action" => "Request scoped pilot authorization to enable marketplace_tool_sidecars for this project.",
          "validation_run_id" => 123
        }
      })
      create(:pre_commit_requirement, project:, account:, command: "bin/audit")

      render_guided_pane

      expect(response.body).to include("Latest technical prerequisite validation", "Unavailable")
      expect(response.body).to include("Request scoped pilot authorization to enable marketplace_tool_sidecars for this project.")
      expect(response.body).to include("Retry prerequisite validation")
      expect(response.body).to include(validate_technical_prerequisite_project_agent_runs_path(project))
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

  it "opens the current user's canonical interactive chat with one targeted queue lookup" do
    # @spec QUESTION-EXPLORATION-001 @spec QUESTION-EXPLORATION-014
    issue = create(:issue, :needs_input, project:, title: "Alpha question", body: questions_body)
    queries = []
    subscriber = ->(*args) { queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      post inbox_interactive_chat_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue)),
        as: :json
    end

    expect(response).to have_http_status(:created)
    expect(ChatSession.last).to have_attributes(created_by: user, inbox_item_key: "clarifying_questions:#{issue.id}")
    targeted_queue_queries = queries.grep(/FROM "issues" INNER JOIN "projects"/)
    expect(targeted_queue_queries.count).to eq(1)
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

  # @spec OPERATOR-INBOX-003
  it "targets row navigation at the inbox detail frame while advancing history" do
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
    expect(link["data-turbo-frame"]).to eq("inbox-detail")
    expect(link["data-turbo-action"]).to eq("advance")
  end

  it "wires the shared independently scrollable shell panes to the inbox master-detail targets" do
    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-005 @spec LIST-DETAIL-007
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    document = Nokogiri::HTML(response.body)
    list = document.at_css("#inbox-list")
    detail = document.at_css("#inbox-detail-pane")

    expect(list).to be_present
    expect(list["data-inbox-master-detail-target"]).to eq("list")
    expect(list.element_children.first["class"]).to include("lg:overflow-y-auto")
    expect(detail).to be_present
    expect(detail["data-inbox-master-detail-target"]).to eq("detailSection")
    expect(detail.element_children.first["class"]).to include("lg:overflow-y-auto")
  end

  it "supports project scoping" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)
    create(:issue, :needs_input, project: second_project, title: "Beta question", body: questions_body)

    get inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(project.full_name, "Alpha question")
    expect(response.body).not_to include("Beta question")
  end

  # @spec INBOX-FOUNDATION-010
  it "only lists kinds and projects with at least one waiting item in the filters dialog" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)
    untouched_project = create(:project, account: account, created_by: user, active: true, owner: "acme", repo: "gamma")

    get inbox_path

    document = Nokogiri::HTML(response.body)
    expect(document.at_css("input[name='kind'][value='#{Inbox::Queue::CLARIFYING_QUESTIONS_KIND}']")).to be_present
    expect(document.at_css("input[name='kind'][value='#{Inbox::Queue::MANUAL_REVIEW_KIND}']")).to be_nil
    expect(document.at_css("input[name='project_id'][value='#{project.id}']")).to be_present
    expect(document.at_css("input[name='project_id'][value='#{untouched_project.id}']")).to be_nil
  end

  # @spec INBOX-FOUNDATION-010
  it "narrows the Type options to kinds with items in the actively filtered project" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)
    create(:issue, project: second_project, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

    get inbox_path(project_id: project.id)

    document = Nokogiri::HTML(response.body)
    expect(document.at_css("input[name='kind'][value='#{Inbox::Queue::CLARIFYING_QUESTIONS_KIND}']")).to be_present
    expect(document.at_css("input[name='kind'][value='#{Inbox::Queue::MANUAL_REVIEW_KIND}']")).to be_nil
  end

  # @spec INBOX-FOUNDATION-010
  it "narrows the Project options to projects with items of the actively filtered kind" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)
    create(:issue, project: second_project, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

    get inbox_path(kind: Inbox::Queue::MANUAL_REVIEW_KIND)

    document = Nokogiri::HTML(response.body)
    expect(document.at_css("input[name='project_id'][value='#{second_project.id}']")).to be_present
    expect(document.at_css("input[name='project_id'][value='#{project.id}']")).to be_nil
  end

  # @spec INBOX-FOUNDATION-010
  it "embeds the kind<->project matrix so the dialog can narrow options client-side" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_path

    document = Nokogiri::HTML(response.body)
    kind_label = document.at_css("label[data-project-ids]")
    project_label = document.at_css("label[data-kind-ids]")

    expect(kind_label["data-project-ids"]).to eq(project.id.to_s)
    expect(project_label["data-kind-ids"]).to eq(Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
  end

  # @spec INBOX-FOUNDATION-010
  it "shows per-option counts in the filters dialog" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_path

    document = Nokogiri::HTML(response.body)
    kind_label = document.at_css("label[data-project-ids]")

    expect(kind_label.text).to include("Clarifying Questions (1)")
    expect(document.at_css("label[data-kind-ids]").text).to include("#{project.full_name} (1)")
  end

  # @spec INBOX-FOUNDATION-011
  it "redirects a now-empty filter combination back to the unfiltered inbox with a notice" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    get inbox_path(kind: Inbox::Queue::MANUAL_REVIEW_KIND, project_id: project.id)

    expect(response).to redirect_to(inbox_path)
    follow_redirect!
    expect(response.body).to include("No inbox items matched that filter")
    expect(response.body).to include("Alpha question")
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

  it "renders stale manual-merge guidance with approval evidence and no automatic-merge promise" do
    project.update!(auto_merge_mode: "off")
    snapshot = stale_approval_snapshot
    snapshot.fetch("failed").first["approval_evidence"] = {
      "stale_approvals" => [ stale_entry("viamin", "approved123", "current456", 2.hours.ago) ]
    }
    pr = create_merge_approval_pr(title: "Approval blocked PR", snapshot: snapshot)

    visit_merge_approval_entry(pr)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Merge Approval", "PR", "Approval is stale for the current revision", "View PR")
    expect(response.body).to include("Commits were added after the recorded approval", "GitHub still shows Approved")
    expect(response.body).to include("manual merge decision", "Re-approval alone will not cause Paid to merge it")
    expect(response.body).to include("approved123", "current456", "Compare viamin and current revisions on GitHub")
    expect(response.body).not_to include("so Paid can merge it on the next PR scan")
  end

  # @spec OPERATOR-INBOX-002K
  # Regression for #4519: when both the owner and the configured manual
  # reviewer approvals are stale (or when the manual reviewer's stale
  # approval coexists with a fresh owner re-approval), the Inbox detail
  # must surface every approver that failed freshness and link the
  # comparison from THAT approver's recorded revision.
  it "renders each stale approver separately when multiple approvals are stale" do
    project.update!(auto_merge_mode: "off")
    snapshot = stale_approval_snapshot
    snapshot.fetch("failed").first["approval_evidence"] = {
      "stale_approvals" => [
        stale_entry("reviewer", "manual123", "current999", 3.hours.ago),
        stale_entry("viamin", "owner456", "current999", 30.minutes.ago)
      ]
    }
    pr = create_merge_approval_pr(title: "Both stale", snapshot: snapshot)

    visit_merge_approval_entry(pr)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("manual123", "owner456", "current999")
    expect(response.body).to include("Compare", "viamin", "current revisions on GitHub")
    expect(response.body.scan("Approver:").length).to eq(2)
  end

  # @spec OPERATOR-INBOX-002K
  it "renders legacy flat-shaped approval evidence written before the array schema" do
    project.update!(auto_merge_mode: "off")
    snapshot = stale_approval_snapshot
    snapshot.fetch("failed").first["approval_evidence"] = {
      "approved_revision" => "legacy123",
      "approved_at" => 2.hours.ago.iso8601,
      "current_revision" => "legacy456"
    }
    pr = create_merge_approval_pr(title: "Legacy evidence", snapshot: snapshot)

    visit_merge_approval_entry(pr)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("legacy123", "legacy456", "Compare approved and current revisions on GitHub")
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

  # @spec OPERATOR-INBOX-002E @spec INBOX-FOUNDATION-010
  it "exposes retry_limited in the inbox filter panel when a retry-limited item is waiting" do
    create_retry_limited_issue(title: "Capped issue", github_number: 513)

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

  # @spec INBOX-FOUNDATION-010
  it "shows the empty-state copy only when nothing is waiting anywhere" do
    get inbox_path

    expect(response.body).to include("Inbox clear")
    expect(response.body).to include("Paid does not currently have any human-actionable work waiting")
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

  # @spec DESIGN-RECONCILIATION-001
  it "surfaces traceability gaps in the inbox filter and detail pane" do
    finding = create(:design_artifact_finding, project: project, account: project.account,
      artifact_path: "docs/rdrs/RDR-063-example.md", evidence: [ "No explicit qualified issue links were found" ])

    get inbox_path

    document = Nokogiri::HTML(response.body)
    option = document.at_css("input[name='kind'][value='#{Inbox::Queue::TRACEABILITY_GAP_KIND}']")
    expect(option).to be_present

    get inbox_entry_path(entry_id(Inbox::Queue::TRACEABILITY_GAP_KIND, finding), kind: Inbox::Queue::TRACEABILITY_GAP_KIND)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("No explicit qualified issue links were found")
  end

  # @spec DESIGN-RECONCILIATION-001
  it "links traceability-gap pull request artifacts to GitHub pull requests" do
    finding = create(:design_artifact_finding, project: project, account: project.account,
      artifact_path: "pull/100")

    get inbox_entry_path(entry_id(Inbox::Queue::TRACEABILITY_GAP_KIND, finding), kind: Inbox::Queue::TRACEABILITY_GAP_KIND)

    document = Nokogiri::HTML(response.body)

    expect(document.at_css(%(a[href="#{project.github_url}/pull/100"]))).to be_present
  end

  # @spec OPERATOR-INBOX-020 DESIGN-RECONCILIATION-001
  it "keeps informational draft and superseded findings out of the inbox list and detail" do
    draft = create(:design_artifact_finding, project: project, account: project.account, state: "deferred",
      status: "open", artifact_path: "docs/rdrs/RDR-063.md", evidence: [ "Artifact status is Draft" ])

    get inbox_path

    expect(response.body).not_to include("RDR-063.md")

    get inbox_entry_path(entry_id(Inbox::Queue::TRACEABILITY_GAP_KIND, draft), kind: Inbox::Queue::TRACEABILITY_GAP_KIND)

    expect(response).to be_redirect
  end

  # @spec OPERATOR-INBOX-020
  it "presents unavailable coverage as a coverage problem rather than a traceability gap" do
    create(:design_artifact_finding, project: project, account: project.account, state: "unverifiable",
      artifact_path: "docs/rdrs/RDR-064.md", evidence: [ "GitHub coverage was incomplete" ])

    get inbox_path(kind: Inbox::Queue::TRACEABILITY_GAP_KIND)

    expect(response.body).to include("Coverage unavailable: docs/rdrs/RDR-064.md")
    expect(response.body).to include("Coverage Unavailable")
    expect(response.body).not_to include("Traceability gap: docs/rdrs/RDR-064.md")
  end

  # @spec OPERATOR-INBOX-018
  it "exposes a file-issue action so operators can establish ownership when no issue covers the artifact" do
    finding = create(:design_artifact_finding, project: project, account: project.account)

    get inbox_entry_path(entry_id(Inbox::Queue::TRACEABILITY_GAP_KIND, finding), kind: Inbox::Queue::TRACEABILITY_GAP_KIND)

    document = Nokogiri::HTML(response.body)
    expect(document.at_css(%(form[action="#{resolve_design_artifact_finding_path(finding)}"]))).to be_present
    expect(document.at_css(%(form[action="#{file_issue_design_artifact_finding_path(finding)}"]))).to be_present
  end

  # @spec OPERATOR-INBOX-018
  it "exposes a design-PR document-link repair action for stale metadata" do
    finding = create(:design_artifact_finding, project: project, account: project.account, state: "stale_metadata")

    get inbox_entry_path(entry_id(Inbox::Queue::TRACEABILITY_GAP_KIND, finding), kind: Inbox::Queue::TRACEABILITY_GAP_KIND)

    document = Nokogiri::HTML(response.body)
    expect(document.at_css(%(form[action="#{repair_document_links_design_artifact_finding_path(finding)}"]))).to be_present
  end

  # @spec OPERATOR-INBOX-018
  it "rejects an unverified file-issue submit with a stale revision" do
    finding = create(:design_artifact_finding, project: project, account: project.account)

    expect do
      post file_issue_design_artifact_finding_path(finding), params: {
        filing: { revision: "stale", title: "Repair", body: "Cite repair." }
      }
    end.not_to change(Issue, :count)

    expect(finding.reload.status).to eq("open")
    expect(response).to be_redirect
  end

  # @spec OPERATOR-INBOX-018
  it "redirects a filed traceability gap to its durable issue location" do
    finding = create(:design_artifact_finding, project: project, account: project.account)
    remote = OpenStruct.new(
      id: 2_000_001, number: 42, title: "Repair traceability", body: "Cite repair.", state: "open", labels: [],
      user: nil, created_at: Time.current, updated_at: Time.current,
      html_url: "https://github.com/acme/alpha/issues/42", pull_request: nil
    )
    allow(github_client).to receive_messages(search_issues: Data.define(:items).new([]), create_issue: remote)

    post file_issue_design_artifact_finding_path(finding), params: {
      filing: { revision: finding.revision, title: "Repair traceability", body: "Cite repair." }
    }

    issue = finding.reload.resolution_issue
    expect(response).to redirect_to(project_path(project, anchor: "issue_#{issue.id}"))
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
    project.update!(github_token: nil, github_installation: create(:github_installation, :covering_project, account: account, project: project))
    allow(Github::AppInstallation).to receive(:token_for).and_return("installation-token")
    parked = create_manual_review_issue(title: "Parked issue", github_number: 516)
    comment_url = "#{parked.github_url}#issuecomment-1"
    allow(github_client).to receive(:issue_comments).and_return([
      double(body: IssueEnhancements::StopForManualReview::COMMENT_MARKER,
        html_url: comment_url, user: double(login: Github::AppRegistry.bot_login))
    ])

    get inbox_entry_supplement_path(
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

      get inbox_entry_supplement_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

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

      grid = Nokogiri::HTML(response.body).at_css("[data-testid='inbox-question-layout']")
      expect(grid["class"]).to include("lg:has-[[data-testid=inbox-clarifying-context]]:grid")
      expect(grid["class"]).to include("grid-cols-[minmax(0,1fr)_minmax(0,1fr)]")
    end

    it "does not collapse the disclosure on lg+ so the operator does not have to tap to read context" do
      issue = create(:issue, :needs_input, project: project, title: "Context question", body: questions_body)

      get inbox_entry_supplement_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

      panel = Nokogiri::HTML(response.body).at_css("[data-testid='inbox-clarifying-context']")
      # OPERATOR-INBOX-011 expects the context to be visible by default on lg+
      # so the operator does not have to expand the disclosure before reading it.
      # The native <details open> default-expansion is what removes that tap;
      # Nokogiri represents a present boolean attribute as `""`, so we look
      # for the attribute itself rather than a truthy string value.
      expect(panel.attribute("open")).not_to be_nil
      expect(panel.at_css("summary")["class"]).to include("lg:cursor-default")
    end

    it "escapes the fallback text so it never renders as raw HTML before JS runs" do
      issue = create(:issue, :needs_input, project: project, title: "Context question", body: questions_body)

      get inbox_entry_supplement_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))

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
      get inbox_entry_supplement_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))
      expect(response.body).not_to include("data-testid=\"inbox-clarifying-context\"")
      get inbox_entry_path(entry_id(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue))
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
      description: "The quality pause could not be automatically resumed.",
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

  def stale_entry(approver_login, approved_revision, current_revision, approved_at)
    {
      "approver_login" => approver_login,
      "approved_revision" => approved_revision,
      "approved_at" => approved_at.iso8601,
      "current_revision" => current_revision
    }
  end

  def visit_merge_approval_entry(pr)
    get inbox_entry_path(
      entry_id(Inbox::Queue::MERGE_APPROVAL_KIND, pr),
      project_id: project.id,
      kind: Inbox::Queue::MERGE_APPROVAL_KIND
    )
  end

  # @spec LAYERED-VERIFY-015 LAYERED-VERIFY-016
  it "renders finding evidence and records a decision without plan-review actions" do
    finding = create_layered_verification_finding
    check_result = create(:layered_verification_check_result, obligation: finding.obligation, agent_run: finding.agent_run,
      execution_state: "completed", obligation_coverage: "contradicted", cause_signature: "missing-idempotency-guard",
      input_revision: { "code" => "abc123", "intent" => finding.obligation.external_revision })
    finding.update!(observations: [ { "check_result_ids" => [ check_result.id ] } ])
    key = entry_id(Inbox::Queue::LAYERED_VERIFICATION_FINDING_KIND, finding)

    get inbox_entry_path(key), headers: { "Turbo-Frame" => "inbox-detail" }

    expect(response.body).to include("PAYMENTS-017", "Two captures occur after retry.",
      "Only the retry path was exercised.", "Request a separately authorized repair", "Contributing check results",
      "completed", "contradicted", "matches audit revision")
    expect(response.body).not_to include("Approve plan", "Reject plan", "Revise plan")

    post inbox_layered_verification_finding_decision_path(key), params: {
      decision: { action: "defer", reason: "Awaiting a business-owner answer.", external_revision: "abc123" }
    }

    expect(response).to redirect_to(inbox_entry_path(key))
    expect(finding.reload).to have_attributes(status: "deferred")
    expect(finding.decision).to include("selected_action" => "defer", "reason" => "Awaiting a business-owner answer.")
    expect(AgentRun.where(goal: "layered_verification_repair", project:)).to be_empty
  end

  # @spec LAYERED-VERIFY-018
  it "accepts a finding decision when the branch advances without changing the canonical source" do
    finding = create_layered_verification_finding
    finding.obligation.update!(external_revision: "a" * 40, canonical_source_path: "docs/intent/payments-specs.md")
    create(:layered_verification_check_result, obligation: finding.obligation, agent_run: finding.agent_run,
      input_revision: { "external_revision" => "a" * 40 })
    key = entry_id(Inbox::Queue::LAYERED_VERIFICATION_FINDING_KIND, finding)
    allow(github_client).to receive(:ref).with("acme/alpha", "heads/main")
      .and_return(OpenStruct.new(object: OpenStruct.new(sha: "b" * 40)))
    allow(github_client).to receive(:file_content)
      .with("acme/alpha", path: "docs/intent/payments-specs.md", ref: "a" * 40).and_return("same source")
    allow(github_client).to receive(:file_content)
      .with("acme/alpha", path: "docs/intent/payments-specs.md", ref: "b" * 40).and_return("same source")

    post inbox_layered_verification_finding_decision_path(key), params: {
      decision: { action: "defer", reason: "Awaiting a business-owner answer.", external_revision: "abc123" }
    }

    expect(response).to redirect_to(inbox_entry_path(key))
    expect(flash[:alert]).to be_nil
    expect(finding.reload).to have_attributes(status: "deferred")
  end

  # @spec LAYERED-VERIFY-018
  it "rejects a finding decision when the current canonical source content changed" do
    finding = create_layered_verification_finding
    finding.obligation.update!(canonical_source_path: "docs/intent/payments-specs.md")
    key = entry_id(Inbox::Queue::LAYERED_VERIFICATION_FINDING_KIND, finding)
    allow(github_client).to receive(:file_content)
      .with("acme/alpha", path: "docs/intent/payments-specs.md", ref: "abc123")
      .and_return("changed obligation source")

    post inbox_layered_verification_finding_decision_path(key), params: {
      decision: { action: "defer", reason: "Awaiting a business-owner answer.", external_revision: "abc123" }
    }

    expect(response).to redirect_to(inbox_entry_path(key))
    expect(flash[:alert]).to eq("The obligation source changed; review fresh evidence before deciding.")
    expect(finding.reload).to have_attributes(status: "open")
  end

  def create_layered_verification_finding
    source = "PAYMENTS-017 requires one captured charge."
    allow(github_client).to receive(:file_content)
      .with("acme/alpha", path: "docs/intent/payments-specs.md", ref: "abc123").and_return(source)
    obligation = create(:layered_verification_obligation, project:, external_identity: "PAYMENTS-017",
      canonical_source_path: "docs/intent/payments-specs.md",
      scope_description: "Retry a charge without duplicating it.", external_revision: Digest::SHA256.hexdigest(source))
    LayeredVerificationFinding.create!(project:, obligation:,
      agent_run: create(:agent_run, project:, goal: "layered_verification_audit",
        external_metadata: { "layered_verification" => { "target_revision" => "abc123" } }),
      correspondence_claim_type: "spec_to_code", cause_signature: "missing-idempotency-guard",
      source_passages: [ source ],
      observed_behavior: { "summary" => "Two captures occur after retry." },
      check_limitations: [ "Only the retry path was exercised." ],
      decision: { "question" => "How should this discrepancy be handled?",
                  "options" => %w[request_repair approve_clarification defer],
                  "consequences" => [ "Repair requires separate authorization." ] })
  end
end
