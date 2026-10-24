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

  describe "#render" do
    it "serializes clarifying_questions with its questions" do
      entry = build_entry(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, questions: [ "What should happen?" ])

      payload = described_class.render(entry)

      expect(payload).to include(questions: [ "What should happen?" ])
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

      expect(payload.keys).to match_array(%i[id kind waiting_since project title summary action_url])
    end

    it "serializes project_setup_pending with its task descriptions" do
      entry = build_entry(Inbox::Queue::PROJECT_SETUP_PENDING_KIND, tasks: [ "CI is required." ])

      payload = described_class.render(entry)

      expect(payload).to include(tasks: [ "CI is required." ])
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
  end
end
