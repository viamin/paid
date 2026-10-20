# frozen_string_literal: true

require "rails_helper"

# Raised by `assert_navigation_intent!` when an inbox detail partial renders
# an `<a>` or `<form>` that does not declare explicit Turbo navigation intent.
# Top-level so RSpec can resolve it from example bodies.
InboxNavigationIntentViolation = Class.new(StandardError)

# @spec INBOX-NAV-INTENT-001
# Turbo "Content missing" bugs in inbox detail panes keep recurring (#3922,
# #3822, #4031, #4500, #4501) because each new inbox kind must remember to opt
# its actions out of the `inbox-detail` frame. Fix them one button at a time
# no longer — this guard fails CI whenever an inbox detail action navigates
# the frame unintentionally. Every internal `<a>` and `<form>` in the
# rendered detail pane must satisfy exactly one of:
#
# 1. Intentional full navigation — carries `data-turbo-frame="_top"` on the
#    `<a>` itself, or on the `<form>` for `button_to`/`form_with` submissions.
# 2. External link — absolute external URL with `target="_blank"` (and a
#    `rel="noopener noreferrer"`).
# 3. Explicitly whitelisted embedded flow — recognized by the guard via a
#    `data-turbo-frame-spec-whitelist` marker so future embedded Turbo
#    affordances (e.g. "Answer in chat" in `_inbox_detail_clarifying_questions`)
#    opt in deliberately, by name, with a comment in the partial explaining
#    why.
#
# Renders every inbox kind dispatched by `app/views/dashboard/_inbox_detail.html.erb`
# so new kinds inherit the guard automatically — no per-kind opt-in.
#
# The negative test at the bottom (`intentionally nonconforming action`) proves
# the guard bites by rendering a kind with a deliberately nonconforming link
# and expecting the assertion to fire.
RSpec.describe "dashboard inbox detail navigation intent", type: :view do
  let(:account) { TenantContext.with_system_access { create(:account) } }
  let(:owner) { TenantContext.with_system_access { create(:user, :owner, account: account) } }
  let(:project) do
    TenantContext.with_system_access do
      create(:project, account: account, created_by: owner, owner: "acme", repo: "alpha",
        auto_pick_enabled: true, active: true)
    end
  end

  # Build an Entry struct shape (matches Inbox::Queue::Entry) without dragging
  # the queue's full filter pipeline into the view spec; this still exercises
  # the per-partial conditional branches the audit identified
  # (`action_url` present vs. issue vs. agent-run subject, etc.).
  let(:entry_issue) do
    TenantContext.with_system_access do
      create(:issue, project: project, github_number: 7)
    end
  end

  let(:build_entry) do
    ->(kind, **overrides) do
      defaults = {
        id: "#{kind}:1",
        kind: kind,
        project: project,
        issue: entry_issue,
        record: nil,
        waiting_since: nil,
        questions: [],
        tasks: [],
        summary_text: nil,
        title_text: nil,
        action_url: nil,
        guidance: nil,
        closeout_status: nil
      }
      Inbox::Queue::Entry.new(defaults.merge(overrides))
    end
  end

  # Path stubs the partials can depend on without needing the real router.
  # Anything new a partial introduces elsewhere should be added here; failing
  # the route lookup at view time is louder than failing the navigation check.
  before do
    captured_owner = owner
    view.define_singleton_method(:current_user) { captured_owner }
    allow(view).to receive_messages(inbox_query_params: { project_id: project.id, kind: nil, sort: nil }, inbox_path: "/inbox", inbox_interactive_chat_path: "/inbox/chat", project_agent_run_path: "/projects/1/agent_runs/1", project_agent_runs_path: "/projects/1/agent_runs", project_intent_conformance_decisions_path: "/projects/1/intent_conformance_decisions", project_issue_clarifying_questions_chat_path: "/projects/1/issues/1/clarifying_questions/chat", project_issue_clarifying_questions_path: "/projects/1/issues/1/clarifying_questions", request_changes_project_change_intent_path: "/projects/1/change_intents/1/request_changes", approve_project_change_intent_path: "/projects/1/change_intents/1/approve", discard_project_change_intent_path: "/projects/1/change_intents/1/discard", cancel_feature_intent_path: "/feature_intents/1/cancel", approve_feature_intent_path: "/feature_intents/1/approve", approve_plan_review_path: "/plan_reviews/1/approve", reject_plan_review_path: "/plan_reviews/1/reject", revise_plan_review_path: "/plan_reviews/1/revise", link_prerequisite_project_agent_runs_path: "/projects/1/agent_runs/link_prerequisite", resolve_closeout_project_agent_runs_path: "/projects/1/agent_runs/resolve_closeout", request_continuation_project_agent_runs_path: "/projects/1/agent_runs/request_continuation", resume_manual_review_project_agent_runs_path: "/projects/1/agent_runs/resume_manual_review", unblock_escalation_project_agent_runs_path: "/projects/1/agent_runs/unblock_escalation", clear_retry_abandonment_project_agent_runs_path: "/projects/1/agent_runs/clear_retry_abandonment", bootstrap_readiness_project_agent_runs_path: "/projects/1/agent_runs/bootstrap_readiness", partial_closeout_guide_path: "/inbox/partial-closeout-guide", edit_project_path: "/projects/1/edit", inbox_safe_return_target: "/inbox", inbox_entry_path: "/inbox/entry")
    # Pundit policy double — `policy(record).<predicate>?` returns true for
    # every predicate the navigation-relevant partials consult.
    policy_double = Struct.new(:run_agent?, :update?, :approve?).new(true, true, true)
    view.define_singleton_method(:policy) { |_| policy_double }

    # Stash the github context-markdown accessor so a partial calling
    # `entry.context_markdown` doesn't reach the network.
    stub_github_client!
  end

  def stub_github_client!
    github_client = instance_double(GithubClient, issue_comments: [])
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  def render_detail_partial(entry)
    scoped_project = project
    selected_kind = entry.kind
    render partial: "dashboard/inbox_detail", locals: {
      entry: entry,
      scoped_project: scoped_project,
      selected_kind: selected_kind
    }
    Nokogiri::HTML.fragment(rendered)
  end

  # The guard. Walks every <a> and <form> in the detail pane and asserts that
  # each one satisfies exactly one of the three rules.
  def assert_navigation_intent!(fragment, kind:)
    rules_violated = []
    fragment.css("a").each do |anchor|
      href = anchor["href"].to_s
      next if href.empty?
      next if href.start_with?("#") # in-page anchor (no navigation intent)

      has_top_frame = anchor["data-turbo-frame"] == "_top"
      target_blank = anchor["target"] == "_blank"
      rel_noopener = anchor["rel"].to_s.split(/\s+/).include?("noopener")
      whitelisted = anchor["data-turbo-frame-spec-whitelist"].present?

      next if has_top_frame || whitelisted || (target_blank && rel_noopener)

      rules_violated << { kind: kind, kind_hint: "anchor", href: href, html: anchor.to_html.lines.first.to_s.strip }
    end

    fragment.css("form").each do |form|
      has_top_frame = form["data-turbo-frame"] == "_top"
      whitelisted = form["data-turbo-frame-spec-whitelist"].present?

      next if has_top_frame || whitelisted

      rules_violated << { kind: kind, kind_hint: "form", href: form["action"].to_s, html: form.to_html.lines.first.to_s.strip }
    end

    return if rules_violated.empty?

    summary = rules_violated.map do |v|
      "  - inbox kind `#{v[:kind]}` rendered a #{v[:kind_hint]} (href=`#{v[:href]}`) with no explicit Turbo navigation intent.\n" \
        "    snippet: #{v[:html]}"
    end.join("\n")
    raise InboxNavigationIntentViolation, <<~MSG
      #{rules_violated.size} inbox detail actions in kind `#{kind}` violate the navigation policy:

      #{summary}

      Every <a> and <form> in the inbox-detail Turbo Frame must satisfy exactly one of:

      1. `data-turbo-frame="_top"` on the element itself (or on the <form> for `button_to`/`form_with`).
      2. An external link with `target="_blank"` (and a `rel="noopener noreferrer"`).
      3. A whitelisted embedded flow: add `data-turbo-frame-spec-whitelist="<name>"` and a
         code comment in the partial explaining why it intentionally renders inside the frame.
    MSG
  end

  # Per-kind contexts. A new inbox kind inherits the guard automatically when
  # `_inbox_detail.html.erb` is updated to dispatch to a new partial — add a
  # context here that builds the minimum Entry shape the partial needs to
  # render through its branches.
  describe "clarifying_questions" do
    let(:entry) do
      build_entry.call(Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
        record: entry_issue,
        questions: [ "What is X?" ])
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "clarifying_questions")
    end
  end

  describe "plan_review" do
    let(:plan_review_record) do
      TenantContext.with_system_access do
        create(:decomposition_decision,
          project: project,
          issue: entry_issue,
          workflow_id: "planning-workflow-1",
          decision_key: "planning-workflow-1:plan_review:pending",
          decision_type: "planning_outcome",
          outcome: DecompositionDecision::PLAN_PENDING_REVIEW_OUTCOME,
          plan_data: { "tasks" => [ { "title" => "Ship it", "description" => "Land the change end-to-end." } ] })
      end
    end
    let(:entry) do
      build_entry.call(Inbox::Queue::PLAN_REVIEW_KIND,
        record: plan_review_record, issue: entry_issue,
        tasks: [ { "title" => "Ship it", "description" => "Land the change end-to-end." } ])
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "plan_review")
    end
  end

  describe "merge_approval" do
    let(:entry) do
      build_entry.call(Inbox::Queue::MERGE_APPROVAL_KIND,
        guidance: { heading: "Awaiting approval", instruction: "Approve the PR.",
                    approval_evidence: { "stale_approvals" => [] }, blockers: [], stale_approval: false })
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "merge_approval")
    end
  end

  describe "action_required" do
    let(:entry) do
      # The simplest Notification record shape that satisfies
      # `notification.subject.is_a?(AgentRun)` is a real Notification row — the
      # partial's branches only consult `entry.issue`/`notification.subject`,
      # so a plain struct works for the most common (issue) branches and the
      # subject checks just return false.
      build_entry.call(Inbox::Queue::ACTION_REQUIRED_KIND,
        record: Struct.new(:description, :subject, keyword_init: true)
          .new(description: "Resume the project.", subject: nil),
        summary_text: "Resume the project.",
        tasks: [ "Open the dashboard" ])
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent (issue subject)" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "action_required")
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent (action_url present, internal)" do
      entry_with_action_url = build_entry.call(Inbox::Queue::ACTION_REQUIRED_KIND,
        record: Struct.new(:description, :subject, keyword_init: true)
          .new(description: "Configure the project.", subject: nil),
        action_url: "/projects/1/edit",
        summary_text: "Configure the project.")
      allow(view).to receive(:inbox_entry_path).and_return("/inbox/entry-elsewhere")
      fragment = render_detail_partial(entry_with_action_url)
      assert_navigation_intent!(fragment, kind: "action_required")
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent (action_url present, external)" do
      entry_with_action_url = build_entry.call(Inbox::Queue::ACTION_REQUIRED_KIND,
        record: Struct.new(:description, :subject, keyword_init: true)
          .new(description: "Re-grant the GitHub permission.", subject: nil),
        action_url: "https://example.com/runners/1/edit",
        summary_text: "Re-grant the GitHub permission.")
      allow(view).to receive(:inbox_entry_path).and_return("/inbox/entry-elsewhere")
      fragment = render_detail_partial(entry_with_action_url)
      assert_navigation_intent!(fragment, kind: "action_required")
    end
  end

  describe "escalated_pr" do
    let(:escalated_record) do
      # Real Issue row keeps `entry.issue.github_url` resolvable; the
      # `block.record` is the Inbox::EscalatedPullRequests::Entry struct shape
      # the partial consults (reason, counters, operator_paused,
      # last_progress_at).
      Struct.new(:reason, :pull_request, :operator_paused, :counters, :last_progress_at, keyword_init: true)
        .new(reason: Issue::PR_ESCALATION_REASON_AWAITING_APPROVAL, pull_request: entry_issue,
          operator_paused: false, counters: [], last_progress_at: 3.days.ago)
    end
    let(:entry) do
      build_entry.call(Inbox::Queue::ESCALATED_PR_KIND,
        record: escalated_record,
        summary_text: "Awaiting owner approval")
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent (awaiting_approval)" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "escalated_pr")
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent (operational failures)" do
      entry_with_ops_failure = build_entry.call(Inbox::Queue::ESCALATED_PR_KIND,
        record: Struct.new(:reason, :pull_request, :operator_paused, :counters, :last_progress_at, keyword_init: true)
          .new(reason: Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES, pull_request: entry_issue,
            operator_paused: false, counters: [], last_progress_at: 1.hour.ago),
        summary_text: "Operational failures")
      fragment = render_detail_partial(entry_with_ops_failure)
      assert_navigation_intent!(fragment, kind: "escalated_pr")
    end
  end

  describe "manual_review" do
    let(:manual_review_issue) do
      TenantContext.with_system_access do
        issue = create(:issue, project: project, github_number: 11)
        issue.update!(paid_state: "manual_review", manual_review_reason: "Budget cap reached.")
        issue
      end
    end
    let(:entry) do
      build_entry.call(Inbox::Queue::MANUAL_REVIEW_KIND,
        record: manual_review_issue, issue: manual_review_issue,
        summary_text: "Budget cap reached.",
        questions: [ "Override the budget?" ])
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "manual_review")
    end
  end

  describe "intent_conformance" do
    let(:intent_verdict) do
      TenantContext.with_system_access do
        IntentConformanceVerdict.create!(
          project: project,
          issue: entry_issue,
          pr_head_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
          approved_design_revision: "cafef00dcafef00dcafef00dcafef00dcafef00d",
          outcome: "material_drift",
          cited_claims: [ { "design_ref" => "RDR-067", "claim_text" => "Approved scope." } ],
          cited_diff_locations: [ { "file" => "app/foo.rb", "anchor" => "5" } ],
          reasoning_summary: "Off-scope change.",
          evaluated_at: 1.hour.ago,
          reviewer_model: "test-model"
        )
      end
    end
    let(:intent_record) do
      Struct.new(:summary, :verdict, :latest_decision, keyword_init: true)
        .new(summary: "Off-scope change.", verdict: intent_verdict, latest_decision: nil)
    end
    let(:entry) do
      build_entry.call(Inbox::Queue::INTENT_CONFORMANCE_KIND,
        record: intent_record, issue: entry_issue)
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "intent_conformance")
    end
  end

  describe "feature_decision" do
    let(:feature_intent_record) do
      TenantContext.with_system_access do
        create(:feature_intent, :ready_for_approval, project: project, title: "Approve the feature.",
          brief: "Ship the feature.")
      end
    end
    let(:entry) do
      build_entry.call(Inbox::Queue::FEATURE_DECISION_KIND,
        record: feature_intent_record, issue: nil, summary_text: "Ready for approval.",
        title_text: feature_intent_record.title)
    end

    before do
      # `Inbox::FeatureDecisionSummary.call(feature_intent: ...)` reaches into
      # `feature_intent.approved_by` for the approved_waiting_for_merge label;
      # stub it so the trace is happy when the record happens to match that
      # branch too.
      allow(Inbox::FeatureDecisionSummary).to receive(:call).and_return("Ready for approval.")
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "feature_decision")
    end
  end

  describe "retry_limited" do
    let(:retry_issue) do
      TenantContext.with_system_access do
        issue = create(:issue, project: project, github_number: 8)
        issue.update_columns(runner_retry_abandoned_at: 1.hour.ago,
          runner_retry_abandon_reason: "Retry cap reached")
        issue
      end
    end
    let(:entry) do
      build_entry.call(Inbox::Queue::RETRY_LIMITED_KIND,
        issue: retry_issue,
        summary_text: "Retry cap reached.")
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "retry_limited")
    end
  end

  describe "change_intent_draft" do
    let(:change_intent) do
      TenantContext.with_system_access do
        create(:change_intent, :draft, project: project, title: "Prefer sliding window")
      end
    end
    let(:entry) do
      build_entry.call(Inbox::Queue::CHANGE_INTENT_DRAFT_KIND,
        record: change_intent,
        summary_text: change_intent.intent.to_s,
        title_text: change_intent.title)
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "change_intent_draft")
    end
  end

  describe "partial_closeout" do
    let(:stalled_status) do
      Struct.new(:reason, :outcome, :blockers, :unresolved_prerequisites, :evidence, :admissible,
        :open_request, :resolved_current_generation, :stalled?, keyword_init: true)
        .new(reason: "merged partial PR keeps auto-pick off",
          outcome: "Merged partial PR", blockers: [], unresolved_prerequisites: [],
          evidence: Struct.new(:merged_prs, :terminal_at, :no_code_required_at, keyword_init: true)
            .new(merged_prs: [], terminal_at: 1.day.ago, no_code_required_at: nil),
          admissible: false, open_request: nil, resolved_current_generation: false, stalled?: true)
    end
    let(:entry) do
      build_entry.call(Inbox::Queue::PARTIAL_CLOSEOUT_KIND,
        record: entry_issue, closeout_status: stalled_status, issue: entry_issue,
        summary_text: "Merged partial PR keeps this open issue out of automatic scheduling")
    end

    before do
      TenantContext.with_system_access do
        assessment_result = Struct.new(:stale?, :source_revision, :intent_revision,
          :assessment, :criteria, :next_action, :assessed_at, keyword_init: true)
          .new(stale?: false, source_revision: "abc", intent_revision: "def",
            assessment: { "classification" => "partial" }, criteria: [],
            next_action: { "explanation" => "Ask a human." }, assessed_at: nil)
        allow(PartialCloseouts::Assessment).to receive(:call).and_return(assessment_result)
      end
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "partial_closeout")
    end
  end

  describe "test_review_pending" do
    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      entry = build_entry.call(Inbox::Queue::TEST_REVIEW_PENDING_KIND)
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "test_review_pending")
    end
  end

  describe "project_setup_pending" do
    let(:project_for_setup) do
      TenantContext.with_system_access do
        create(:project, account: account, created_by: owner, owner: "acme", repo: "beta",
          auto_pick_enabled: true, active: true, tdd_mode: "strict",
          readiness_gaps: [ { "kind" => "missing_ci", "description" => "CI is required.", "evidence" => {} } ])
      end
    end
    let(:entry) do
      build_entry.call(Inbox::Queue::PROJECT_SETUP_PENDING_KIND,
        project: project_for_setup, record: project_for_setup, issue: nil,
        action_url: "/projects/#{project_for_setup.id}/edit",
        summary_text: "1 setup prerequisite needs attention.",
        title_text: "Set up acme/beta",
        tasks: [ "CI is required." ])
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "project_setup_pending")
    end
  end

  describe "traceability_gap" do
    let(:finding) do
      TenantContext.with_system_access do
        DesignArtifactFinding.create!(
          project: project,
          account: account,
          fingerprint: Digest::SHA256.hexdigest("gap-fingerprint"),
          artifact_path: "docs/rdrs/RDR-063-example.md",
          revision: "abcdef0123",
          state: "missing_tree",
          evidence: [ "No links were found." ],
          covered_at: Time.current,
          status: "open"
        )
      end
    end
    let(:entry) do
      build_entry.call(Inbox::Queue::TRACEABILITY_GAP_KIND,
        record: finding, issue: nil, tasks: [ "No links were found." ],
        summary_text: "Missing tree", title_text: "Traceability gap: docs/rdrs/RDR-063-example.md")
    end

    it "every <a> and <form> in the detail pane declares explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      assert_navigation_intent!(fragment, kind: "traceability_gap")
    end
  end

  # @spec INBOX-NAV-INTENT-002
  # The negative test: render an inbox detail partial with an additional
  # nonconforming element and run the guard against the augmented fragment —
  # proves the guard's assertion bites so a future regression cannot silently
  # disable it. The harness injects a deliberately nonconforming anchor so
  # the assertion has a known violation to detect.
  describe "guard bites on a nonconforming action (negative test)" do
    let(:entry) { build_entry.call(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, record: entry_issue, questions: [ "What is X?" ]) }

    it "raises InboxNavigationIntentViolation when an internal <a> in the detail pane has no explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      augmented_fragment = Nokogiri::HTML.fragment(fragment.to_html + '<a href="/inbox/never-set">Missing intent</a>')

      expect {
        assert_navigation_intent!(augmented_fragment, kind: "clarifying_questions")
      }.to raise_error(InboxNavigationIntentViolation, %r{/inbox/never-set})
    end

    it "raises InboxNavigationIntentViolation when an internal <form> in the detail pane has no explicit Turbo navigation intent" do
      fragment = render_detail_partial(entry)
      augmented_fragment = Nokogiri::HTML.fragment(fragment.to_html + '<form action="/forbidden"><button>Go</button></form>')

      expect {
        assert_navigation_intent!(augmented_fragment, kind: "clarifying_questions")
      }.to raise_error(InboxNavigationIntentViolation, %r{/forbidden})
    end

    it "does NOT raise when a newly added action declares `data-turbo-frame=_top`" do
      fragment = render_detail_partial(entry)
      augmented_fragment = Nokogiri::HTML.fragment(
        fragment.to_html + '<a href="/inbox/allowed" data-turbo-frame="_top">Allowed</a>'
      )

      expect {
        assert_navigation_intent!(augmented_fragment, kind: "clarifying_questions")
      }.not_to raise_error
    end
  end
end
