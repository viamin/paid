# frozen_string_literal: true

require "rails_helper"

# @spec MOBILE-API-006
RSpec.describe Api::V1::InboxEntrySerializer do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  def build_entry(kind, overrides = {})
    Inbox::Queue::Entry.new(
      **{
        id: "#{kind}:1",
        kind: kind,
        project: project,
        issue: nil,
        record: nil,
        waiting_since: Time.current,
        questions: [],
        tasks: [],
        summary_text: "summary",
        title_text: "title",
        action_url: nil
      }.merge(overrides)
    )
  end

  def layered_verification_detail
    audit = create(:agent_run, project:, goal: "layered_verification_audit",
      external_metadata: { "layered_verification" => { "target_revision" => "audit-revision" } })
    obligation = create(:layered_verification_obligation, project:, framework: "lid", external_identity: "PAYMENTS-42",
      external_revision: "source-revision", canonical_source_path: "docs/intent/payments/specs.md",
      scope_description: "Keep charge settlement idempotent.", approved_revision_reference: "https://github.com/acme/widgets/pull/42")
    contributing = create(:layered_verification_check_result, obligation:, agent_run: audit,
      producer: "implementation_conformance", execution_state: "failed_assertion", obligation_coverage: "contradicted",
      input_revision: { "intent" => "audit-revision" }, limitations: "Only the submitted patch was observed.",
      evidence_ref: "audit://checks/42", evidence_summary: { "passage" => "settlement retries twice" }, cause_signature: "duplicate-settlement")
    unrelated = create(:layered_verification_check_result, obligation:, agent_run: audit,
      producer: "formal_verification", execution_state: "completed", obligation_coverage: "supported")
    finding = create(:layered_verification_finding, project:, obligation:, agent_run: audit,
      source_passages: [ { "source" => "spec", "text" => "one settlement per charge" } ],
      observed_behavior: { "behavior" => "the worker can settle twice", "check_results" => [ contributing.id ] },
      check_limitations: [ "The production retry schedule was not exercised." ],
      decision: { "question" => "How should this discrepancy be handled?", "options" => %w[request_repair approve_clarification defer],
                  "consequences" => [ "Repair requires separate authorization." ] })
    { audit:, obligation:, contributing:, unrelated:, finding: }
  end

  def expected_layered_verification_payload(detail)
    {
      obligation: { external_identity: "PAYMENTS-42", framework: "lid", scope_description: "Keep charge settlement idempotent.",
                    approval_state: "proposed", source_revision: "source-revision",
                    approved_revision_reference: "https://github.com/acme/widgets/pull/42",
                    canonical_source_path: "docs/intent/payments/specs.md" },
      audit: { id: detail[:audit].id, target_revision: "audit-revision" },
      source_passages: [ { "source" => "spec", "text" => "one settlement per charge" } ],
      observed_behavior: { "behavior" => "the worker can settle twice", "check_results" => [ detail[:contributing].id ] },
      check_limitations: [ "The production retry schedule was not exercised." ],
      decision: include(question: "How should this discrepancy be handled?", consequences: [ "Repair requires separate authorization." ]),
      supported_actions: %w[request_repair approve_clarification defer]
    }
  end

  def sql_queries
    queries = []
    callback = ->(_name, _started, _finished, _id, payload) { queries << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  describe "#render" do
    # @spec MOBILE-API-006 MCP-INBOX-TOOLS-002
    it "declares a detail contract for every queue kind" do
      expect(described_class::KIND_DETAIL_CONTRACT.keys).to match_array(Inbox::Queue::KINDS)
      expect(described_class::KIND_DETAIL_CONTRACT.fetch(Inbox::Queue::LAYERED_VERIFICATION_FINDING_KIND))
        .to eq(:verification_evidence)
    end

    it "serializes clarifying_questions with its questions" do
      issue = create(:issue, project: project)
      entry = build_entry(Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
        issue:, questions: [ "What should happen?" ])

      payload = described_class.render(entry)

      expect(payload).to include(questions: [ "What should happen?" ])
      expect(payload).not_to have_key(:workflow)
    end

    it "serializes plan_review with its tasks" do
      entry = build_entry(Inbox::Queue::PLAN_REVIEW_KIND, tasks: [ { "title" => "Do the thing" } ])

      payload = described_class.render(entry)

      expect(payload).to include(tasks: [ { "title" => "Do the thing" } ])
    end

    it "serializes merge_approval with its normalized guidance" do
      issue = create(:issue, :pull_request, project: project,
        auto_merge_blockers: { "failed" => [ { "signal" => "owner_approved" } ], "not_evaluated" => [] })
      guidance = { heading: "Manual merge decision on GitHub", blockers: [ { "signal" => "owner_approved", "next_action" => "Make the manual decision." } ] }
      entry = build_entry(Inbox::Queue::MERGE_APPROVAL_KIND, issue: issue, record: issue, guidance: guidance)

      payload = described_class.render(entry)

      expect(payload).to include(blockers: guidance.fetch(:blockers), guidance: guidance)
      expect(payload.fetch(:workflow)).to include(
        current_action: "Make the manual decision.",
        milestones: include(
          a_hash_including(name: "Owner approval", state: "current"),
          a_hash_including(name: "Merge", state: "waiting")
        )
      )
    end

    # @spec AUTO-MERGE-015 OPERATOR-INBOX-028
    it "serializes technical blockers without presenting them as human approval" do
      issue = create(:issue, :pull_request, project: project, last_scanned_head_sha: "a" * 40)
      guidance = { current_head: "a" * 40, next_eligible_action: "Reconcile the release condition against the current PR head.",
                   blockers: [ { "key" => "safe_worker_adoption", "release_condition" => "Verify adoption" } ] }
      entry = build_entry(Inbox::Queue::TECHNICAL_MERGE_BLOCKER_KIND, issue: issue, record: issue, guidance: guidance)

      expect(described_class.render(entry)).to include(technical_merge_blockers: guidance.fetch(:blockers),
        current_head: "a" * 40, next_eligible_action: guidance.fetch(:next_eligible_action))
    end

    it "includes the detail-only progress projection without adding it to list payloads" do
      issue = create(:issue, :pull_request, project: project, last_scanned_head_sha: "a" * 40)
      entry = build_entry(Inbox::Queue::MERGE_APPROVAL_KIND, issue: issue, record: issue)

      expect(described_class.render(entry).fetch(:progress)).to include(current_head: "a" * 40)
      expect(described_class.render_list(entry)).not_to have_key(:progress)
    end

    it "serializes action_required with its remediation steps" do
      entry = build_entry(Inbox::Queue::ACTION_REQUIRED_KIND, tasks: [ "Grant the missing permission" ])

      payload = described_class.render(entry)

      expect(payload).to include(remediation_steps: [ "Grant the missing permission" ])
    end

    it "serializes escalated_pr with the reason, counters, last progress, and operator-pause state" do
      pull_request = create(:issue, :pull_request, project: project)
      counters = [ Inbox::EscalatedPullRequests::Counter.new(name: :draft_review_count, value: 3, limit: 3) ]
      last_progress_at = 2.days.ago
      blocked = Inbox::EscalatedPullRequests::Entry.new(
        pull_request: pull_request,
        reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
        blocked_since: 1.day.ago,
        counters: counters,
        last_progress_at: last_progress_at,
        operator_paused: true
      )
      entry = build_entry(Inbox::Queue::ESCALATED_PR_KIND, issue: pull_request, record: blocked)

      payload = described_class.render(entry)

      expect(payload).to include(
        reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
        counters: [ { name: :draft_review_count, value: 3, limit: 3 } ],
        last_progress_at: last_progress_at.iso8601,
        operator_paused: true
      )
    end

    it "serializes manual_review with its questions and comment url" do
      marker_comment = double(
        body: "#{IssueEnhancements::StopForManualReview::COMMENT_MARKER}\nsome text",
        html_url: "https://github.com/acme/widgets/issues/5#comment",
        user: double(login: "paid-agent[bot]")
      )
      github_client = instance_double(GithubClient, issue_comments: [ marker_comment ])
      allow(GithubClient).to receive(:new).and_return(github_client)
      allow(project).to receive(:paid_bot_author?).and_return(true)
      issue = create(:issue, :needs_input, project: project)
      entry = build_entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue: issue, record: issue, questions: [ "Still open?" ])

      payload = described_class.render(entry)

      expect(payload).to include(
        questions: [ "Still open?" ],
        comment_url: "https://github.com/acme/widgets/issues/5#comment"
      )
    end

    it "serializes intent_conformance with the verdict and latest decision" do
      issue = create(:issue, :pull_request, project: project)
      verdict = create(:intent_conformance_verdict, :material_drift, project: project, issue: issue)
      decision = create(:intent_conformance_decision, issue: issue, verdict: verdict)
      snapshot = Inbox::IntentConformance::Snapshot.new(issue: issue, verdict: verdict, decisions: [ decision ])
      entry = build_entry(Inbox::Queue::INTENT_CONFORMANCE_KIND, issue: issue, record: snapshot)

      payload = described_class.render(entry)

      expect(payload[:verdict]).to include(outcome: IntentConformanceVerdict::OUTCOME_MATERIAL_DRIFT)
      expect(payload[:latest_decision]).to include(action: decision.action, reason: decision.reason)
    end

    it "serializes intent_conformance with nil verdict/decision when none are recorded" do
      issue = create(:issue, :pull_request, project: project)
      snapshot = Inbox::IntentConformance::Snapshot.new(issue: issue, verdict: nil, decisions: [])
      entry = build_entry(Inbox::Queue::INTENT_CONFORMANCE_KIND, issue: issue, record: snapshot)

      payload = described_class.render(entry)

      expect(payload).to include(verdict: nil, latest_decision: nil)
    end

    it "serializes feature_decision with the approval readiness blockers" do
      feature_intent = create(:feature_intent, project: project, status: "discovering")
      entry = build_entry(Inbox::Queue::FEATURE_DECISION_KIND, record: feature_intent)

      payload = described_class.render(entry)

      expect(payload[:ready]).to be false
      expect(payload[:blockers]).to include(a_hash_including(code: "not_approvable_status"))
    end

    it "serializes feature_decision as ready when no blockers apply" do
      feature_intent = create(:feature_intent, :ready_for_approval, project: project)
      entry = build_entry(Inbox::Queue::FEATURE_DECISION_KIND, record: feature_intent)

      payload = described_class.render(entry)

      expect(payload).to include(ready: true, blockers: [])
    end

    it "serializes confidence policy actions without an approval action" do # @spec CONFIDENCE-DELIVERY-016
      feature_intent = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_decision, feature_intent: feature_intent, kind: "question")
      entry = build_entry(Inbox::Queue::FEATURE_DECISION_KIND, record: feature_intent)

      payload = described_class.render(entry)

      expect(payload).to include(delivery_policy: "confidence_driven")
      expect(payload[:human_actions]).to include(a_hash_including(kind: "answer_or_clarify"))
      expect(payload[:human_actions]).not_to include(a_hash_including(kind: "approve"))
    end

    it "serializes the shared planning decision context" do # @spec OPERATOR-INBOX-021
      feature_intent = create(:feature_intent, :confidence_driven, project: project)
      decision = create(:feature_intent_decision, feature_intent: feature_intent)
      issue = create(:issue, project: project, github_number: 73, title: "Validate sidecar")
      create(:feature_intent_issue, feature_intent: feature_intent, issue: issue)
      create(:feature_intent_design_pr, feature_intent: feature_intent, pull_request_number: 74,
        head_sha: "design-revision", reviewed_head_sha: nil)
      entry = build_entry(Inbox::Queue::FEATURE_DECISION_KIND, record: feature_intent)

      payload = described_class.render(entry)

      expect(payload[:decisions]).to include(a_hash_including(id: decision.id, prompt: decision.prompt))
      expect(payload[:affected_tasks]).to include(a_hash_including(number: 73, title: "Validate sidecar"))
      expect(payload[:design_revisions]).to include(a_hash_including(number: 74, revision: "design-revision", state: "open"))
    end

    it "serializes retry_limited with the push-permission flag and return count" do
      issue = create(:issue, project: project,
        runner_retry_abandon_reason: "All available runners reached the per-issue retry cap (3).",
        runner_retry_abandonment_count: 2)
      entry = build_entry(Inbox::Queue::RETRY_LIMITED_KIND, issue: issue, record: issue)

      payload = described_class.render(entry)

      expect(payload).to include(push_permission_abandoned: false, return_count: 1)
    end

    it "serializes change_intent_draft with its intent fields" do
      change_intent = create(:change_intent, project: project)
      entry = build_entry(Inbox::Queue::CHANGE_INTENT_DRAFT_KIND, record: change_intent)

      payload = described_class.render(entry)

      expect(payload).to include(
        intent: change_intent.intent,
        behavior: change_intent.behavior,
        constraints: change_intent.constraints,
        decisions_made: change_intent.decisions_made,
        requested_changes_reason: change_intent.requested_changes_reason
      )
    end

    it "serializes partial_closeout with the unresolved prerequisites" do
      entry = build_entry(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, tasks: [ "owner/repo#41" ])

      payload = described_class.render(entry)

      expect(payload).to include(unresolved_prerequisites: [ "owner/repo#41" ])
    end

    it "serializes test_review_pending with just the common fields" do
      entry = build_entry(Inbox::Queue::TEST_REVIEW_PENDING_KIND)

      payload = described_class.render(entry)

      expect(payload.keys).to match_array(%i[id kind waiting_since project title summary action_url decision_brief history history_incomplete history_next_cursor])
    end

    it "serializes project_setup_pending with its task descriptions" do
      entry = build_entry(Inbox::Queue::PROJECT_SETUP_PENDING_KIND, tasks: [ "CI is required." ])

      payload = described_class.render(entry)

      expect(payload).to include(tasks: [ "CI is required." ])
    end

    # @spec LAYERED-VERIFY-015 MCP-INBOX-TOOLS-002 MOBILE-API-008
    it "serializes bounded layered-verification evidence and supported decision context" do
      detail = layered_verification_detail
      payload = described_class.render(build_entry(Inbox::Queue::LAYERED_VERIFICATION_FINDING_KIND, record: detail[:finding]))

      expect(payload).to include(expected_layered_verification_payload(detail))
      expect(payload.fetch(:contributing_check_results)).to eq([
        {
          id: detail[:contributing].id, producer: "implementation_conformance", execution_state: "failed_assertion",
          obligation_coverage: "contradicted", input_revision: { "intent" => "audit-revision" },
          freshness: "matches_audit_revision", limitations: "Only the submitted patch was observed.",
          evidence_ref: "audit://checks/42", evidence_summary: { "passage" => "settlement retries twice" }
        }
      ])
      expect(payload.fetch(:contributing_check_results).map { |result| result.fetch(:id) }).not_to include(detail[:unrelated].id)
    end

    # @spec DESIGN-RECONCILIATION-001
    it "serializes traceability_gap with the finding's actionable evidence" do
      finding = create(:design_artifact_finding, project: project,
        artifact_path: "docs/rdrs/RDR-123.md", revision: "abc123", state: "partial_tree",
        evidence: [ "Missing linked issue acme/widgets#42" ])
      entry = build_entry(Inbox::Queue::TRACEABILITY_GAP_KIND, record: finding, tasks: finding.evidence)

      payload = described_class.render(entry)

      expect(payload).to include(
        artifact_path: "docs/rdrs/RDR-123.md",
        revision: "abc123",
        state: "partial_tree",
        evidence: [ "Missing linked issue acme/widgets#42" ]
      )
    end

    # @spec OPERATOR-INBOX-020
    it "serializes unverifiable coverage as an access problem with a recovery action" do
      finding = create(:design_artifact_finding, project: project,
        artifact_path: "docs/rdrs/RDR-124.md", revision: "abc123", state: "unverifiable",
        evidence: [ "GitHub coverage was incomplete" ])
      entry = build_entry(Inbox::Queue::TRACEABILITY_GAP_KIND,
        record: finding, tasks: finding.evidence, title_text: "Coverage unavailable: docs/rdrs/RDR-124.md")

      payload = described_class.render(entry)

      expect(payload[:recommended_action]).to eq("Restore coverage access and recheck.")
      expect(payload[:title]).to eq("Coverage unavailable: docs/rdrs/RDR-124.md")
      expect(payload[:summary]).not_to include("Traceability gap")
    end

    # @spec AUTO-PICK-QUEUE-020
    it "serializes dependency_cycle path/edge nodes with title, labels, and authorized umbrella context" do
      parent = create(:issue, project: project, title: "Ship the whole epic")
      first = create(:issue, project: project, github_state: "open", parent_issue: parent, labels: [ "bug" ])
      second = create(:issue, project: project, github_state: "open")
      create(:issue_dependency, issue: first, depends_on_issue: second)
      create_legacy_issue_dependency(issue: second, depends_on_issue: first)
      cycle = Issues::DependencyCycles.call(account: account).sole.with(visible_parent_project_ids: Set.new([ project.id ]))
      entry = build_entry(Inbox::Queue::DEPENDENCY_CYCLE_KIND, record: cycle)

      payload = described_class.render(entry)

      first_node = payload.fetch(:cycle_path).find { |node| node.fetch(:number) == first.github_number }
      second_node = payload.fetch(:cycle_path).find { |node| node.fetch(:number) == second.github_number }
      expect(first_node).to include(
        title: first.title,
        labels: [ "bug" ],
        parent: { project: project.full_name, number: parent.github_number, url: parent.github_url, title: parent.title }
      )
      expect(second_node).to include(title: second.title, labels: [], parent: nil)
      expect(payload.fetch(:cycle_edges)).to include(a_hash_including(from: first_node, to: second_node))
    end

    it "raises for an unrecognized kind rather than silently returning an empty payload" do
      entry = build_entry("unknown_kind")

      expect { described_class.render(entry) }.to raise_error(ArgumentError, /unknown_kind/)
    end
  end

  describe "#render_list" do
    it "serializes manual_review list entries without resolving the comment url" do
      entry = build_entry(Inbox::Queue::MANUAL_REVIEW_KIND, questions: [ "Still open?" ])
      expect(entry).not_to receive(:manual_review_comment_url)

      payload = described_class.render_list(entry)

      expect(payload).to include(questions: [ "Still open?" ])
      expect(payload).not_to have_key(:comment_url)
    end

    # @spec LAYERED-VERIFY-015 MCP-INBOX-TOOLS-001 MCP-INBOX-TOOLS-002 MOBILE-API-008
    it "keeps layered-verification evidence on the detail projection" do
      detail = layered_verification_detail
      entry = build_entry(Inbox::Queue::LAYERED_VERIFICATION_FINDING_KIND, record: detail[:finding])

      payload = nil
      queries = sql_queries { payload = described_class.render_list(entry) }

      expect(payload).not_to include(
        :obligation, :audit, :source_passages, :observed_behavior, :check_limitations,
        :decision, :supported_actions, :contributing_check_results
      )
      expect(queries).not_to include(a_string_matching(/FROM "layered_verification_check_results"/))
    end
  end

  # @spec OPERATOR-INBOX-027
  describe ".render_list_page" do
    # @spec OPERATOR-INBOX-027
    it "batches approved goal context for the returned work items" do
      entries = 2.times.map do |index|
        issue = create(:issue, project:, title: "Queue item #{index}")
        feature = create(:feature_intent, project:, title: "Feature #{index}", brief: "Approved outcome #{index}",
          approved_design_revision: (index + 1).to_s * 40)
        create(:feature_intent_issue, feature_intent: feature, issue:)
        build_entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue: issue.reload)
      end
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:sql].include?("feature_intents") }

      payloads = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        described_class.render_list_page(entries)
      end

      expect(payloads.map { |payload| payload.dig(:decision_brief, :goal) }).to eq([ "Approved outcome 0", "Approved outcome 1" ])
      expect(payloads.map { |payload| payload.dig(:decision_brief, :goal_source) })
        .to eq([ "Approved feature intent: Feature 0", "Approved feature intent: Feature 1" ])
      expect(queries.size).to eq(1)
    end

    # @spec OPERATOR-INBOX-027
    it "preserves every linked approved intent when one issue serves two released designs" do
      issue = create(:issue, project:, title: "Shared work item")
      first_design = create(:feature_intent, project:, title: "Design one", brief: "First agreed outcome.",
        approved_design_revision: "a" * 40, approved_revision_recorded_at: 3.days.ago)
      second_design = create(:feature_intent, project:, title: "Design two", brief: "Second agreed outcome.",
        approved_design_revision: "b" * 40, approved_revision_recorded_at: 1.day.ago)
      create(:feature_intent_issue, feature_intent: first_design, issue:)
      create(:feature_intent_issue, feature_intent: second_design, issue:)
      entry = build_entry(Inbox::Queue::MANUAL_REVIEW_KIND, id: "manual_review:#{issue.id}", issue: issue.reload)

      brief = described_class.render_list_page([ entry ]).sole.fetch(:decision_brief)

      expect(brief.fetch(:goal)).to eq("This work item serves more than one approved feature intent.")
      expect(brief).not_to have_key(:goal_revision)
      expect(brief.fetch(:linked_goal_intents)).to contain_exactly(
        { goal: "First agreed outcome.", source: "Approved feature intent: Design one", revision: "a" * 40 },
        { goal: "Second agreed outcome.", source: "Approved feature intent: Design two", revision: "b" * 40 }
      )
    end

    it "batches local prerequisite titles for the returned entries" do
      entries = 2.times.map do |index|
        prerequisite = create(:issue, project:, github_number: 510 + index, title: "Verify result #{index}")
        blocked = create(:issue, project:, github_number: 520 + index)
        create(:issue_dependency, issue: blocked, depends_on_issue: prerequisite)
        build_entry(Inbox::Queue::PARTIAL_CLOSEOUT_KIND,
          id: "partial_closeout:#{blocked.id}", issue: blocked.reload, tasks: [ "##{prerequisite.github_number}" ])
      end
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:sql].include?("issue_dependencies") }

      payloads = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        described_class.render_list_page(entries)
      end

      expect(payloads.map { |payload| payload.dig(:decision_brief, :recommendation) })
        .to eq([ "Resolve the prerequisite: Verify result 0.", "Resolve the prerequisite: Verify result 1." ])
      expect(queries.size).to eq(1)
    end
  end
end
