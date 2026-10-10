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

    it "serializes merge_approval with the issue's failed auto-merge blockers" do
      issue = create(:issue, :pull_request, project: project,
        auto_merge_blockers: { "failed" => [ { "signal" => "owner_approved" } ], "not_evaluated" => [] })
      entry = build_entry(Inbox::Queue::MERGE_APPROVAL_KIND, issue: issue, record: issue)

      payload = described_class.render(entry)

      expect(payload).to include(blockers: [ { "signal" => "owner_approved" } ])
    end

    it "serializes action_required with its remediation steps" do
      entry = build_entry(Inbox::Queue::ACTION_REQUIRED_KIND, tasks: [ "Grant the missing permission" ])

      payload = described_class.render(entry)

      expect(payload).to include(remediation_steps: [ "Grant the missing permission" ])
    end

    it "serializes escalated_pr with the reason, counters, last progress, and operator-pause state" do
      pull_request = create(:issue, :pull_request, project: project)
      counters = [ Dashboard::BlockedPullRequests::Counter.new(name: :draft_review_count, value: 3, limit: 3) ]
      last_progress_at = 2.days.ago
      blocked = Dashboard::BlockedPullRequests::Entry.new(
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

    it "raises for an unrecognized kind rather than silently returning an empty payload" do
      entry = build_entry("unknown_kind")

      expect { described_class.render(entry) }.to raise_error(ArgumentError, /unknown_kind/)
    end
  end
end
