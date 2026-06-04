# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoReview do
  let(:strategy) { described_class.new }
  let(:project) { create(:project) }
  let(:pull_request) do
    create(:issue, :pull_request, project: project, github_number: 42, paid_state: "new")
  end

  def evaluate(scan: nil)
    context = Automation::Context.build(
      record: pull_request,
      project: project,
      metadata: scan.nil? ? {} : { scan: scan }
    )
    strategy.evaluate(context)
  end

  it "is an Automation::Strategy" do
    expect(described_class.ancestors).to include(Automation::Strategy)
  end

  it "returns noop when no scan is provided" do
    expect(evaluate.to_h).to eq(decisions: [ { type: "noop" } ])
  end

  describe "trigger routing" do
    it "routes paid_agent_review_pending to a queue_review_run decision" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: [ { type: "paid_agent_review_pending" } ]
      })

      expect(result.to_h).to eq(
        decisions: [
          {
            type: "queue_review_run",
            issue_id: pull_request.id,
            source_pull_request_number: 42,
            focus: "general"
          }
        ]
      )
    end

    it "suppresses follow-up decisions while paid_agent_review_pending is outstanding (#1135)" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        current_draft_review_count: 0,
        triggers: [
          { type: "paid_agent_review_pending" },
          { type: "ci_failure", details: [ "test-suite" ] }
        ]
      })

      types = result.to_h[:decisions].map { |d| d[:type] }
      expect(types).to include("queue_review_run")
      expect(types).not_to include("queue_create_pr_run")
    end

    it "emits neither create_pr nor followup when paid_agent is already running with other triggers" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_followup_count: 0,
        triggers: [
          { type: "paid_agent_review_pending", active_run: true },
          { type: "merge_conflicts", details: "PR has merge conflicts" }
        ]
      })

      types = result.to_h[:decisions].map { |d| d[:type] }
      expect(types).not_to include("queue_create_pr_run")
      expect(types).not_to include("record_pr_followup")
    end

    it "routes to create_pr when paid_agent review is pending but not running and merge_conflicts is present (#2324)" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_followup_count: 0,
        labels_to_remove: [],
        triggers: [
          { type: "paid_agent_review_pending" },
          { type: "merge_conflicts", details: "PR has merge conflicts" }
        ]
      })

      types = result.to_h[:decisions].map { |d| d[:type] }
      expect(types).to include("queue_create_pr_run")
      expect(types).not_to include("queue_review_run")
    end

    it "routes review_bot_review_pending to a request_review decision for the trigger login" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        triggers: [
          { type: "review_bot_review_pending", request_login: "copilot" }
        ]
      })

      expect(result.to_h).to eq(
        decisions: [
          { type: "request_review", pr_number: 42, reviewers: [ "copilot" ] }
        ]
      )
    end

    it "suppresses follow-up decisions while review_bot_review_pending is outstanding (#1336)" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_followup_count: 0,
        triggers: [
          { type: "review_bot_review_pending", request_login: "copilot" },
          { type: "ci_failure", details: [ "test-suite" ] }
        ]
      })

      expect(result.to_h).to eq(
        decisions: [
          { type: "request_review", pr_number: 42, reviewers: [ "copilot" ] }
        ]
      )
    end

    it "suppresses follow-up decisions for auto-review bot pending triggers with no request login" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_followup_count: 0,
        triggers: [
          { type: "review_bot_review_pending", request_login: nil },
          { type: "merge_conflicts", details: "PR has merge conflicts" }
        ]
      })

      expect(result.to_h).to eq(decisions: [ { type: "noop" } ])
    end

    it "keeps follow-up decisions for posted bot feedback while review_bot_review_pending is outstanding" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_followup_count: 0,
        labels_to_remove: [],
        triggers: [
          { type: "review_bot_review_pending", request_login: "copilot" },
          { type: "review_bot_comments", details: [ "Please update the tests" ] }
        ]
      })

      expect(result.to_h).to eq(
        decisions: [
          { type: "request_review", pr_number: 42, reviewers: [ "copilot" ] },
          { type: "queue_create_pr_run", issue_id: pull_request.id, source_pull_request_number: 42, focus: "general" },
          { type: "record_pr_followup", issue_id: pull_request.id, labels_to_remove: [], expected_followup_count: 0 }
        ]
      )
    end

    it "emits the trigger's reviewer for manual_review_pending" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: [
          { type: "manual_review_pending", reviewer_login: "alice" }
        ]
      })

      expect(result.to_h[:decisions].first).to include(
        type: "request_review",
        reviewers: [ "alice" ]
      )
    end

    it "falls through to follow-up decisions when no review-specific trigger is present but a ci_failure is" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_followup_count: 0,
        labels_to_remove: [ "paid-needs-input" ],
        triggers: [ { type: "ci_failure", details: "test-suite" } ]
      })

      types = result.to_h[:decisions].map { |d| d[:type] }
      expect(types).to eq(%w[queue_create_pr_run record_pr_followup])
    end

    it "emits an escalate decision on escalate_to_owner triggers" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "escalated",
        owner_reviewer_login: "bob",
        triggers: [ { type: "escalate_to_owner", details: "paid_agent retry budget exhausted" } ]
      })

      expect(result.to_h[:decisions].first).to include(
        type: "escalate",
        pr_number: 42,
        owner_reviewer_login: "bob",
        reason: "paid_agent retry budget exhausted"
      )
    end

    it "emits a mark_draft decision on demote_to_draft triggers" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: [ { type: "demote_to_draft" } ]
      })

      expect(result.to_h[:decisions].first).to include(
        type: "mark_draft",
        issue_id: pull_request.id,
        pr_number: 42
      )
    end

    it "emits a merge decision on owner_approved triggers" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: [ { type: "owner_approved" } ]
      })

      expect(result.to_h[:decisions].first).to include(
        type: "merge",
        issue_id: pull_request.id,
        pr_number: 42
      )
    end

    it "routes review_goal_retry to both a record_review_goal_retry and a queue_review_run decision" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        current_review_goal_retry_count: 1,
        triggers: [ { type: "review_goal_retry" } ]
      })

      types = result.to_h[:decisions].map { |d| d[:type] }
      expect(types).to include("record_review_goal_retry", "queue_review_run")
    end

    it "suppresses retry follow-up decisions while review_bot_review_pending is outstanding" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_review_goal_retry_count: 1,
        current_followup_count: 0,
        triggers: [
          { type: "review_goal_retry" },
          { type: "review_bot_review_pending", request_login: "copilot" },
          { type: "ci_failure", details: [ "test-suite" ] }
        ]
      })

      types = result.to_h[:decisions].map { |d| d[:type] }
      expect(types).to include("record_review_goal_retry", "queue_review_run", "request_review")
      expect(types).not_to include("queue_create_pr_run", "record_pr_followup")
    end

    it "keeps retry follow-up decisions for posted bot feedback while review_bot_review_pending is outstanding" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_review_goal_retry_count: 1,
        current_followup_count: 0,
        labels_to_remove: [],
        triggers: [
          { type: "review_goal_retry" },
          { type: "review_bot_review_pending", request_login: "copilot" },
          { type: "review_bot_threads", details: [ "Please update the tests" ] }
        ]
      })

      types = result.to_h[:decisions].map { |d| d[:type] }
      expect(types).to include("record_review_goal_retry", "queue_review_run", "request_review")
      expect(types).to include("queue_create_pr_run", "record_pr_followup")
    end

    it "marks ready on ready_for_owner triggers" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        owner_reviewer_login: "bob",
        triggers: [ { type: "ready_for_owner" } ]
      })

      expect(result.to_h[:decisions].first).to include(
        type: "mark_ready",
        issue_id: pull_request.id,
        pr_number: 42,
        owner_reviewer_login: "bob"
      )
    end

    it "queues a paid_agent review run alongside mark_ready when ready_for_owner overlaps with paid_agent_review_pending" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        owner_reviewer_login: "bob",
        triggers: [
          { type: "ready_for_owner" },
          { type: "paid_agent_review_pending" }
        ]
      })

      types = result.to_h[:decisions].map { |d| d[:type] }
      expect(types).to include("queue_review_run", "mark_ready")
    end

    it "does NOT queue a paid_agent review run when ready_for_owner overlaps with an already-running paid_agent" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        owner_reviewer_login: "bob",
        triggers: [
          { type: "ready_for_owner" },
          { type: "paid_agent_review_pending", active_run: true }
        ]
      })

      types = result.to_h[:decisions].map { |d| d[:type] }
      expect(types).to eq([ "mark_ready" ])
    end

    it "falls through to standard follow-up decisions for a scan with no triggers" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: []
      })

      expect(result.to_h[:decisions]).to eq([
        { type: "queue_create_pr_run", issue_id: pull_request.id, source_pull_request_number: 42, focus: "general" },
        { type: "record_pr_followup", issue_id: pull_request.id, labels_to_remove: [], expected_followup_count: nil }
      ])
    end
  end

  describe "#outcomes_for" do
    it "returns one outcome per known review method" do
      outcomes = strategy.outcomes_for(project: project, scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        triggers: [ { type: "paid_agent_review_pending" } ]
      })

      expect(outcomes.map(&:method)).to match_array(%i[copilot paid_agent codex ci_action manual])
      paid_agent = outcomes.find { |o| o.method == :paid_agent }
      expect(paid_agent).to be_pending
    end
  end
end
