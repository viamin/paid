# frozen_string_literal: true

require "rails_helper"

# Tests verifying retry semantics in AutoReview: how the strategy
# handles retryable failures, exhausted retries, and the interaction
# between review-goal retries and other triggers.
RSpec.describe Automation::Strategies::AutoReview do
  context "with retry semantics" do
  let(:strategy) { described_class.new }
  let(:project) { create(:project) }
  let(:pull_request) do
    create(:issue, :pull_request, project: project, github_number: 42, paid_state: "new")
  end

  def evaluate(scan: {})
    context = Automation::Context.build(
      record: pull_request,
      project: project,
      metadata: { scan: scan }
    )
    strategy.evaluate(context)
  end

  def decision_types(result)
    result.to_h[:decisions].map { |d| d[:type] }
  end

  describe "review_goal_retry trigger" do
    it "emits both record_review_goal_retry and queue_review_run" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        current_review_goal_retry_count: 1,
        triggers: [ { type: "review_goal_retry" } ]
      })

      types = decision_types(result)
      expect(types).to include("record_review_goal_retry", "queue_review_run")
    end

    it "includes the retry count in record_review_goal_retry payload" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        current_review_goal_retry_count: 3,
        triggers: [ { type: "review_goal_retry" } ]
      })

      retry_decision = result.to_h[:decisions].find { |d| d[:type] == "record_review_goal_retry" }
      expect(retry_decision[:expected_review_goal_retry_count]).to eq(3)
    end
  end

  describe "review_goal_retry with copilot pending" do
    it "suppresses follow-up decisions but keeps retry and review request" do
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

      types = decision_types(result)
      expect(types).to include("record_review_goal_retry", "queue_review_run", "request_review")
      expect(types).not_to include("queue_create_pr_run", "record_pr_followup")
    end
  end

  describe "review_goal_retry with posted bot feedback" do
    it "queues a follow-up instead of retrying review when bot has already posted feedback" do
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

      types = decision_types(result)
      expect(types).to eq(%w[queue_create_pr_run record_pr_followup])
    end
  end

  describe "escalate_to_owner trigger (retry budget exhausted)" do
    it "emits an escalate decision with reason" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "escalated",
        owner_reviewer_login: "bob",
        triggers: [ { type: "escalate_to_owner", details: "paid_agent retry budget exhausted" } ]
      })

      escalate = result.to_h[:decisions].first
      expect(escalate[:type]).to eq("escalate")
      expect(escalate[:reason]).to eq("paid_agent retry budget exhausted")
      expect(escalate[:owner_reviewer_login]).to eq("bob")
    end

    it "takes priority over other triggers" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "escalated",
        owner_reviewer_login: "bob",
        triggers: [
          { type: "escalate_to_owner", details: "budget exhausted" },
          { type: "ci_failure", details: [ "test-suite" ] }
        ]
      })

      types = decision_types(result)
      expect(types).to eq([ "escalate" ])
    end
  end

  describe "paid_agent_review_pending with active run" do
    it "suppresses all decisions when a paid_agent run is already active" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: [ { type: "paid_agent_review_pending", active_run: true } ]
      })

      types = decision_types(result)
      expect(types).to eq([ "noop" ])
    end
  end
  end
end
