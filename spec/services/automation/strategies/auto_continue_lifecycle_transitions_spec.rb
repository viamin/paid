# frozen_string_literal: true

require "rails_helper"

# Tests verifying lifecycle transition semantics in AutoContinue:
# gate priority, phase transitions, and delegation to AutoReview.
RSpec.describe Automation::Strategies::AutoContinue do
  context "with lifecycle transitions" do
  let(:strategy) { described_class.new }
  let(:project) { create(:project) }
  let(:pull_request) do
    create(:issue, :pull_request, project: project, github_number: 42, paid_state: "new")
  end

  def evaluate(lifecycle: nil, scan: nil)
    metadata = {}
    metadata[:lifecycle] = lifecycle if lifecycle
    metadata[:scan] = scan if scan

    context = Automation::Context.build(
      record: pull_request,
      project: project,
      metadata: metadata
    )
    strategy.evaluate(context)
  end

  def decision_types(result)
    result.to_h[:decisions].map { |d| d[:type] }
  end

  def base_lifecycle(phase: "ready", **overrides)
    {
      issue_id: pull_request.id,
      pr_number: 42,
      phase: phase,
      active_run_exists: false,
      operational_failure_breaker: false,
      no_progress_stuck: false,
      failure_streak_limit_reached: false,
      owner_reviewer_login: "alice",
      escalation_reason: nil,
      consecutive_unsuccessful_automatic_runs: 0,
      consecutive_operational_failures: 0,
      last_meaningful_progress_at: nil,
      draft: phase == "draft" || phase == "restarted"
    }.merge(overrides)
  end

  describe "gate priority ordering" do
    it "active_run_exists trumps all other gates" do
      result = evaluate(
        lifecycle: base_lifecycle(
          active_run_exists: true,
          operational_failure_breaker: true,
          no_progress_stuck: true,
          escalation_reason: "failures"
        ),
        scan: { issue_id: pull_request.id, pr_number: 42, phase: "ready", triggers: [] }
      )

      expect(decision_types(result)).to eq([ "noop" ])
    end
  end

  describe "draft phase gates" do
    it "escalates on the unified failure streak limit" do
      result = evaluate(
        lifecycle: base_lifecycle(
          phase: "draft",
          failure_streak_limit_reached: true,
          no_progress_stuck: true,
          consecutive_unsuccessful_automatic_runs: 3,
          escalation_reason: "Automatic PR failure streak reached"
        )
      )

      decisions = result.to_h[:decisions]
      expect(decisions.first[:type]).to eq("escalate")
      expect(decisions.first[:reason]).to eq("Automatic PR failure streak reached")
    end

    it "escalates on draft-phase streak exhaustion" do
      result = evaluate(
        lifecycle: base_lifecycle(
          phase: "draft",
          failure_streak_limit_reached: true,
          no_progress_stuck: true,
          consecutive_unsuccessful_automatic_runs: 3,
          escalation_reason: "Automatic PR failure streak reached"
        )
      )

      expect(result.to_h[:decisions].first[:type]).to eq("escalate")
    end

    it "delegates to AutoReview when all draft gates pass" do
      result = evaluate(
        lifecycle: base_lifecycle(phase: "draft"),
        scan: {
          issue_id: pull_request.id,
          pr_number: 42,
          phase: "draft",
          current_draft_review_count: 0,
          triggers: [ { type: "ci_failure", details: [ "test-suite" ] } ]
        }
      )

      types = decision_types(result)
      expect(types).to include("queue_create_pr_run")
    end
  end

  describe "restarted phase gates" do
    it "treats restarted like draft for gate evaluation" do
      result = evaluate(
        lifecycle: base_lifecycle(
          phase: "restarted",
          failure_streak_limit_reached: true,
          no_progress_stuck: true,
          consecutive_unsuccessful_automatic_runs: 3,
          escalation_reason: "Automatic PR failure streak reached"
        )
      )

      expect(result.to_h[:decisions].first[:type]).to eq("escalate")
    end
  end

  describe "ready phase gates" do
    it "delegates to AutoReview when no unified gate is active" do
      result = evaluate(
        lifecycle: base_lifecycle(phase: "ready"),
        scan: { issue_id: pull_request.id, pr_number: 42, phase: "ready", triggers: [] }
      )

      expect(decision_types(result)).to eq([ "queue_create_pr_run", "record_pr_followup" ])
    end

    it "escalates on the unified failure streak limit" do
      result = evaluate(
        lifecycle: base_lifecycle(
          phase: "ready",
          failure_streak_limit_reached: true,
          no_progress_stuck: true,
          consecutive_unsuccessful_automatic_runs: 3,
          escalation_reason: "Automatic PR failure streak reached"
        )
      )

      expect(result.to_h[:decisions].first[:type]).to eq("escalate")
    end

    it "delegates to AutoReview when all ready gates pass" do
      result = evaluate(
        lifecycle: base_lifecycle(phase: "ready"),
        scan: {
          issue_id: pull_request.id,
          pr_number: 42,
          phase: "ready",
          triggers: [ { type: "owner_approved" } ]
        }
      )

      expect(result.to_h[:decisions].first[:type]).to eq("merge")
    end
  end

  describe "escalated phase gates" do
    it "delegates to AutoReview when no unified gate is active" do
      result = evaluate(
        lifecycle: base_lifecycle(phase: "escalated"),
        scan: { issue_id: pull_request.id, pr_number: 42, phase: "escalated", triggers: [] }
      )

      expect(decision_types(result)).to eq([ "queue_create_pr_run", "record_pr_followup" ])
    end

    it "escalates on the unified failure streak limit" do
      result = evaluate(
        lifecycle: base_lifecycle(
          phase: "escalated",
          failure_streak_limit_reached: true,
          no_progress_stuck: true,
          consecutive_unsuccessful_automatic_runs: 3,
          escalation_reason: "Automatic PR failure streak reached"
        )
      )

      expect(result.to_h[:decisions].first[:type]).to eq("escalate")
    end
  end

  describe "delegation without lifecycle" do
    it "falls back to AutoReview when no lifecycle signals present" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: [ { type: "owner_approved" } ]
      })

      expect(result.to_h[:decisions].first[:type]).to eq("merge")
    end

    it "returns noop when neither lifecycle nor scan is provided" do
      result = evaluate
      expect(decision_types(result)).to eq([ "noop" ])
    end
  end

  describe "scan data forwarding" do
    it "passes scan through to AutoReview when gates pass" do
      result = evaluate(
        lifecycle: base_lifecycle(phase: "ready"),
        scan: {
          issue_id: pull_request.id,
          pr_number: 42,
          phase: "ready",
          triggers: [ { type: "paid_agent_review_pending" } ]
        }
      )

      expect(decision_types(result)).to include("queue_review_run")
    end

    it "returns noop when gates pass but no scan data is present" do
      result = evaluate(lifecycle: base_lifecycle(phase: "ready"))

      expect(decision_types(result)).to eq([ "noop" ])
    end
  end
  end
end
