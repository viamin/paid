# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoContinue do
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

  it "is an Automation::Strategy" do
    expect(described_class.ancestors).to include(Automation::Strategy)
  end

  describe "backwards compatibility" do
    it "delegates to AutoReview when no lifecycle signals are present" do
      result = evaluate(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: [ { type: "owner_approved" } ]
      })

      expect(result.to_h[:decisions].first).to include(type: "merge")
    end

    it "returns noop when neither lifecycle nor scan is provided" do
      result = evaluate
      expect(result.to_h).to eq(decisions: [ { type: "noop" } ])
    end
  end

  describe "lifecycle gates" do
    let(:base_lifecycle) do
      {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        active_run_exists: false,
        operational_failure_breaker: false,
        draft_review_limit_reached: false,
        consecutive_draft_failures_breaker: false,
        review_goal_retry_limit_requires_escalation: false,
        followup_limit_reached: false,
        escalation_dismissed: false,
        owner_reviewer_login: "alice",
        escalation_reason: nil,
        draft: false
      }
    end

    context "when an active run exists" do
      it "returns noop" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(active_run_exists: true),
          scan: { issue_id: pull_request.id, pr_number: 42, phase: "ready", triggers: [] }
        )

        expect(decision_types(result)).to eq([ "noop" ])
      end
    end

    context "when operational failure breaker trips" do
      it "returns an escalate decision" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(
            operational_failure_breaker: true,
            escalation_reason: "Consecutive operational failures (3 runs)"
          )
        )

        decisions = result.to_h[:decisions]
        expect(decisions.first).to include(
          type: "escalate",
          issue_id: pull_request.id,
          pr_number: 42,
          owner_reviewer_login: "alice",
          reason: "Consecutive operational failures (3 runs)"
        )
      end
    end

    context "when escalation is dismissed" do
      it "returns a dismiss_escalation decision" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(
            phase: "escalated",
            escalation_dismissed: true,
            draft: false
          )
        )

        decisions = result.to_h[:decisions]
        expect(decisions.first).to include(
          type: "dismiss_escalation",
          issue_id: pull_request.id
        )
      end
    end

    context "when in draft phase" do
      let(:draft_lifecycle) { base_lifecycle.merge(phase: "draft", draft: true) }

      it "escalates when review goal retry limit requires escalation" do
        result = evaluate(
          lifecycle: draft_lifecycle.merge(
            review_goal_retry_limit_requires_escalation: true,
            escalation_reason: "Review-goal retry limit reached"
          )
        )

        expect(result.to_h[:decisions].first).to include(type: "escalate")
      end

      it "escalates when draft review limit is reached" do
        result = evaluate(
          lifecycle: draft_lifecycle.merge(
            draft_review_limit_reached: true,
            escalation_reason: "Draft review limit reached"
          )
        )

        expect(result.to_h[:decisions].first).to include(type: "escalate")
      end

      it "escalates when consecutive draft failures breaker trips" do
        result = evaluate(
          lifecycle: draft_lifecycle.merge(
            consecutive_draft_failures_breaker: true,
            escalation_reason: "Consecutive draft follow-up failures"
          )
        )

        expect(result.to_h[:decisions].first).to include(type: "escalate")
      end
    end

    context "when in restarted phase" do
      let(:restarted_lifecycle) { base_lifecycle.merge(phase: "restarted", draft: true) }

      it "escalates when draft review limit is reached" do
        result = evaluate(
          lifecycle: restarted_lifecycle.merge(
            draft_review_limit_reached: true,
            escalation_reason: "Draft review limit reached"
          )
        )

        expect(result.to_h[:decisions].first).to include(type: "escalate")
      end
    end

    context "when in ready phase" do
      it "escalates when review goal retry limit requires escalation" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(
            review_goal_retry_limit_requires_escalation: true,
            escalation_reason: "Review-goal retry limit reached"
          )
        )

        expect(result.to_h[:decisions].first).to include(type: "escalate")
      end

      it "returns noop when followup limit is reached" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(followup_limit_reached: true),
          scan: { issue_id: pull_request.id, pr_number: 42, phase: "ready", triggers: [] }
        )

        expect(decision_types(result)).to eq([ "noop" ])
      end
    end

    context "when in escalated phase" do
      let(:escalated_lifecycle) { base_lifecycle.merge(phase: "escalated") }

      it "escalates when review goal retry limit requires escalation" do
        result = evaluate(
          lifecycle: escalated_lifecycle.merge(
            review_goal_retry_limit_requires_escalation: true,
            escalation_reason: "Review-goal retry limit reached"
          )
        )

        expect(result.to_h[:decisions].first).to include(type: "escalate")
      end

      it "returns noop when followup limit is reached" do
        result = evaluate(
          lifecycle: escalated_lifecycle.merge(followup_limit_reached: true),
          scan: { issue_id: pull_request.id, pr_number: 42, phase: "escalated", triggers: [] }
        )

        expect(decision_types(result)).to eq([ "noop" ])
      end
    end
  end

  describe "delegation to AutoReview" do
    let(:base_lifecycle) do
      {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        active_run_exists: false,
        operational_failure_breaker: false,
        draft_review_limit_reached: false,
        consecutive_draft_failures_breaker: false,
        review_goal_retry_limit_requires_escalation: false,
        followup_limit_reached: false,
        escalation_dismissed: false,
        owner_reviewer_login: "alice",
        escalation_reason: nil,
        draft: false
      }
    end

    it "returns noop when gates pass but no scan data is present" do
      result = evaluate(lifecycle: base_lifecycle)

      expect(decision_types(result)).to eq([ "noop" ])
    end

    it "delegates to AutoReview when gates pass and scan data is present" do
      result = evaluate(
        lifecycle: base_lifecycle,
        scan: {
          issue_id: pull_request.id,
          pr_number: 42,
          phase: "ready",
          triggers: [ { type: "owner_approved" } ]
        }
      )

      expect(result.to_h[:decisions].first).to include(type: "merge")
    end

    it "delegates follow-up decisions through AutoReview" do
      result = evaluate(
        lifecycle: base_lifecycle,
        scan: {
          issue_id: pull_request.id,
          pr_number: 42,
          phase: "ready",
          current_followup_count: 0,
          labels_to_remove: [],
          triggers: [ { type: "ci_failure", details: "test-suite" } ]
        }
      )

      types = decision_types(result)
      expect(types).to include("queue_create_pr_run", "record_pr_followup")
    end
  end

  describe "gate priority" do
    let(:base_lifecycle) do
      {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        active_run_exists: false,
        operational_failure_breaker: false,
        draft_review_limit_reached: false,
        consecutive_draft_failures_breaker: false,
        review_goal_retry_limit_requires_escalation: false,
        followup_limit_reached: false,
        escalation_dismissed: false,
        owner_reviewer_login: "alice",
        escalation_reason: nil,
        draft: true
      }
    end

    it "active_run_exists takes priority over breakers" do
      result = evaluate(
        lifecycle: base_lifecycle.merge(
          active_run_exists: true,
          operational_failure_breaker: true,
          escalation_reason: "Consecutive operational failures"
        ),
        scan: { issue_id: pull_request.id, pr_number: 42, phase: "draft", triggers: [] }
      )

      expect(decision_types(result)).to eq([ "noop" ])
    end

    it "operational failure breaker takes priority over escalation dismissed" do
      result = evaluate(
        lifecycle: base_lifecycle.merge(
          phase: "escalated",
          operational_failure_breaker: true,
          escalation_dismissed: true,
          escalation_reason: "Consecutive operational failures"
        )
      )

      expect(result.to_h[:decisions].first).to include(type: "escalate")
    end
  end
end
