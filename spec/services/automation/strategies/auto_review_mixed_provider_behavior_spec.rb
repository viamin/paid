# frozen_string_literal: true

require "rails_helper"

# Tests verifying that AutoReview correctly composes decisions when
# multiple review methods are enabled simultaneously. These cover the
# mixed-provider behavior that is critical to preserve during the
# modularization migration.
RSpec.describe Automation::Strategies::AutoReview do
  context "with mixed review-provider behavior" do
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

  describe "paid_agent + copilot both pending" do
    it "emits only the paid_agent queue_review_run (paid_agent suppresses follow-ups)" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        triggers: [
          { type: "paid_agent_review_pending" },
          { type: "review_bot_review_pending", request_login: "copilot" }
        ]
      })

      types = decision_types(result)
      expect(types).to include("queue_review_run")
      expect(types).not_to include("request_review")
    end
  end

  describe "copilot + codex both pending" do
    it "emits request_review for the copilot bot only (copilot trigger takes priority)" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        triggers: [
          { type: "review_bot_review_pending", request_login: "copilot" },
          { type: "review_bot_review_pending", request_login: "chatgpt-codex-connector" }
        ]
      })

      expect(result.to_h).to eq(
        decisions: [
          { type: "request_review", pr_number: 42, reviewers: [ "copilot" ] }
        ]
      )
    end
  end

  describe "manual review pending + ci_failure" do
    it "emits both a request_review and follow-up decisions" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_followup_count: 0,
        labels_to_remove: [],
        triggers: [
          { type: "manual_review_pending", reviewer_login: "alice" },
          { type: "ci_failure", details: [ "test-suite" ] }
        ]
      })

      types = decision_types(result)
      expect(types).to include("request_review")
      expect(types).to include("queue_create_pr_run")
    end
  end

  describe "ci_action pending alone" do
    it "emits dispatch_claude_review when dispatch is required" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        triggers: [
          { type: "ci_action_pending", dispatch_required: true }
        ]
      })

      types = decision_types(result)
      expect(types).to include("dispatch_claude_review")
    end
  end

  describe "review_bot_comments with copilot pending" do
    it "allows follow-up decisions through when bot has already posted feedback" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_followup_count: 0,
        labels_to_remove: [],
        triggers: [
          { type: "review_bot_review_pending", request_login: "copilot" },
          { type: "review_bot_comments", details: [ "Fix the tests" ] }
        ]
      })

      types = decision_types(result)
      expect(types).to include("request_review")
      expect(types).to include("queue_create_pr_run")
      expect(types).to include("record_pr_followup")
    end
  end

  describe "no review triggers, only follow-up triggers" do
    it "falls through to follow-up decisions for ci_failure" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_followup_count: 0,
        labels_to_remove: [ "paid-needs-input" ],
        triggers: [ { type: "ci_failure", details: "test-suite" } ]
      })

      types = decision_types(result)
      expect(types).to eq(%w[queue_create_pr_run record_pr_followup])
    end
  end

  describe "no triggers at all" do
    it "emits standard follow-up decisions for ready phase" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: []
      })

      types = decision_types(result)
      expect(types).to eq(%w[queue_create_pr_run record_pr_followup])
    end

    it "emits draft follow-up decisions for draft phase" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        current_draft_review_count: 0,
        triggers: []
      })

      types = decision_types(result)
      expect(types).to eq(%w[queue_create_pr_run])

      decisions = result.to_h[:decisions]
      expect(decisions.first[:count_toward_draft_review_round]).to be true
    end
  end
  end
end
