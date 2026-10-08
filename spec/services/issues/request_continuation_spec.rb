# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::RequestContinuation do # @spec PARTIAL-CLOSEOUT-003 @spec PARTIAL-CLOSEOUT-004 @spec PARTIAL-CLOSEOUT-008
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:reason) { "The merged PR intentionally deferred the remaining work; audit it now." }

  def merged_partial_pr(number:)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )
  end

  def request_continuation(actor: user, issue: self.issue, reason: self.reason)
    described_class.call(issue: issue, actor: actor, reason: reason)
  end

  describe "success" do
    it "persists the authorization and queues exactly one continuation run" do
      merged_partial_pr(number: 12)

      result = request_continuation

      expect(result.success?).to be(true)
      request = result.request
      expect(request.requested_by).to eq(user)
      expect(request.reason).to eq(reason)
      expect(request.evidence_digest).to eq(Issues::CloseoutEvidence.call(issue).digest)
      expect(request.evidence["merged_prs"].map { |pr| pr["number"] }).to contain_exactly(12)

      run = result.agent_run
      expect(run.status).to eq("queued")
      expect(run.goal).to eq("create_pr")
      expect(run.trigger_type).to eq("manual")
      expect(run.continuation_request_id).to eq(request.id)
      expect(run.initiating_user).to eq(user)
    end

    it "enqueues ProcessRunQueueJob" do
      merged_partial_pr(number: 12)

      expect { request_continuation }.to have_enqueued_job(ProcessRunQueueJob)
    end

    it "records an audit event" do
      merged_partial_pr(number: 12)

      request_continuation

      event = account.account_activity_events.where(action: "issue.continuation_requested").last
      expect(event).to be_present
      expect(event.actor).to eq(user)
      expect(event.subject).to eq(issue)
    end
  end

  describe "idempotency across double-clicks, replay, and concurrent requests" do
    it "returns the existing open request without queueing a second run" do
      merged_partial_pr(number: 12)
      first = request_continuation

      second = request_continuation

      expect(second.success?).to be(true)
      expect(second.request.id).to eq(first.request.id)
      expect(second.agent_run.id).to eq(first.agent_run.id)
      expect(issue.agent_runs.count).to eq(1)
    end

    it "rescues the unique-index race and reports the existing request" do
      merged_partial_pr(number: 12)
      existing = create(:issue_continuation_request, issue: issue, project: project, requested_by: user)
      # First lookup misses (simulating a concurrent insert landing between
      # the pre-check and the insert); the rescue path re-queries and finds it.
      allow(IssueContinuationRequest).to receive(:open_for_issue).and_return(nil, existing)
      expect(IssueContinuationRequest).to receive(:create!).and_call_original

      result = request_continuation

      expect(result.success?).to be(true)
      expect(result.request.id).to eq(existing.id)
    end
  end

  describe "refusals" do
    it "refuses an issue without closeout evidence" do
      result = request_continuation

      expect(result.success?).to be(false)
      expect(result.code).to eq(:not_stalled)
      expect(result.message).to include("no terminal closeout evidence")
      expect(issue.agent_runs).to be_empty
      expect(IssueContinuationRequest.count).to eq(0)
    end

    it "refuses a paused issue without bypassing the pause" do
      merged_partial_pr(number: 12)
      issue.update_columns(paused: true)

      result = request_continuation

      expect(result.code).to eq(:operator_pause)
      expect(result.message).to include("paused")
    end

    it "refuses a skip-labeled issue" do
      merged_partial_pr(number: 12)
      skip_label = project.effective_auto_pick_skip_labels.first || "paid:skip"
      issue.update!(labels: [ skip_label ])

      result = request_continuation

      expect(result.code).to eq(:operator_pause)
      expect(result.message).to include(skip_label)
    end

    it "refuses a needs-input issue" do
      merged_partial_pr(number: 12)
      issue.update!(paid_state: "needs_input")

      result = request_continuation

      expect(result.code).to eq(:operator_pause)
      expect(result.message).to include("needs input")
    end

    it "refuses a manual-review issue" do
      merged_partial_pr(number: 12)
      issue.update!(paid_state: "manual_review", manual_review_reason: "parked")

      result = request_continuation

      expect(result.code).to eq(:operator_pause)
    end

    it "refuses while the project is explicitly paused" do
      merged_partial_pr(number: 12)
      project.update!(paused: true)

      result = request_continuation

      expect(result.code).to eq(:operator_pause)
    end

    it "refuses when an unmet prerequisite blocks the issue and names it" do
      merged_partial_pr(number: 12)
      blocker = create(:issue, project: project, github_state: "open", github_number: 44)
      create(:issue_dependency, issue: issue, depends_on_issue: blocker)

      result = request_continuation

      expect(result.code).to eq(:unmet_prerequisites)
      expect(result.message).to include("#44")
    end

    it "refuses an untrusted creator's issue" do
      merged_partial_pr(number: 12)
      issue.update!(github_creator_login: "random-stranger")

      result = request_continuation

      expect(result.code).to eq(:untrusted)
    end

    it "refuses when a run is already in flight for the issue" do
      merged_partial_pr(number: 12)
      create(:agent_run, :queued, project: project, issue: issue, goal: "create_pr")

      result = request_continuation

      expect(result.code).to eq(:run_in_flight)
    end

    it "refuses when a feature-intent release gate holds the issue" do
      merged_partial_pr(number: 12)
      feature = create(:feature_intent, project: project, status: "approved_waiting_for_merge")
      create(:feature_intent_issue, feature_intent: feature, issue: issue)

      result = request_continuation

      expect(result.code).to eq(:feature_held)
      expect(result.message).to include("Feature intent")
    end

    it "refuses when an active issue-analysis backoff holds the issue" do
      merged_partial_pr(number: 12)
      issue.update_columns(
        issue_analysis_next_attempt_at: 2.hours.from_now,
        issue_analysis_backoff_set_at: 1.hour.ago
      )

      result = request_continuation

      expect(result.code).to eq(:analysis_backoff)
      expect(result.message).to include("backoff")
      expect(issue.agent_runs).to be_empty
      expect(IssueContinuationRequest.count).to eq(0)
    end

    it "refuses instead of queueing a run another eligibility guard would cancel at dequeue" do
      # A guard the targeted blocker walk does not enumerate (here: an open
      # non-PR sub-issue keeps the parent out of every eligible scope) must
      # refuse up front with its reason, never queue a run the dequeue-time
      # recheck would cancel and supersede (#4130 review).
      merged_partial_pr(number: 12)
      create(
        :issue,
        project: project,
        github_state: "open",
        paid_state: "in_progress",
        parent_issue_id: issue.id,
        github_number: 55
      )

      result = request_continuation

      expect(result.success?).to be(false)
      expect(result.code).to eq(:unavailable)
      expect(result.message).to include("exact guard is unavailable")
      expect(issue.agent_runs).to be_empty
      expect(IssueContinuationRequest.count).to eq(0)
    end

    it "refuses when the project budget is exhausted" do
      merged_partial_pr(number: 12)
      create(:cost_budget, :monthly, :exceeded, :hard_stop, project: project)

      result = request_continuation

      expect(result.code).to eq(:budget_exhausted)
    end

    it "refuses a blank reason" do
      merged_partial_pr(number: 12)

      result = request_continuation(reason: "  ")

      expect(result.code).to eq(:invalid_reason)
    end
  end

describe "prompt delivery" do # @spec PARTIAL-CLOSEOUT-013
    before do
      stub_request(:get, %r{api\.github\.com/repos/.*/issues/.*/comments})
        .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
    end

    it "delivers the operator's reason and evidence snapshot into the final assembled agent prompt" do
      merged_partial_pr(number: 12)

      result = request_continuation

      prompt = result.agent_run.prompt_for_issue

      expect(prompt).to include("# Continuation Context")
      expect(prompt).to include(reason)
      expect(prompt).to include("Merged pull request #12")
      expect(prompt).to include("continuation request ##{result.request.id}")
      # Standard issue, policy, and style context is preserved alongside it.
      expect(prompt).to include(issue.title)
      expect(prompt).to include("MUST pass before every commit")
    end

    it "does not alter the prompt for an ordinary (non-continuation) run on the same issue" do
      other_issue = create(:issue, project: project, github_state: "open")
      ordinary_run = create(:agent_run, project: project, issue: other_issue, goal: "create_pr")

      prompt = ordinary_run.prompt_for_issue

      expect(prompt).not_to include("Continuation Context")
    end
  end

  describe "re-arming after a consumed request" do
    it "allows a fresh deliberate continuation once the prior run finished" do
      merged_partial_pr(number: 12)
      first = request_continuation
      first.agent_run.cancel!(error: "operator cancelled")
      expect(first.request.reload.status).to eq("consumed")

      second = request_continuation(reason: "Second deliberate attempt after audit.")

      expect(second.success?).to be(true)
      expect(second.request.id).not_to eq(first.request.id)
      expect(issue.agent_runs.count).to eq(2)
    end
  end
end
