# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::EscalationService do
  describe ".call" do
    let(:project) do
      create(:project,
        owner_reviewer_login: "alice",
        allowed_github_usernames: [ "alice", "viamin" ])
    end
    let(:issue) do
      create(:issue, :pull_request,
        project: project,
        github_number: 42,
        pr_review_phase: "ready")
    end

    let(:base_signals) do
      {
        issue_id: issue.id,
        pr_number: issue.github_number,
        phase: issue.pr_review_phase,
        active_run_exists: false,
        operational_failure_breaker: false,
        draft_review_limit_reached: false,
        consecutive_draft_failures_breaker: false,
        review_goal_retry_limit_requires_escalation: false,
        followup_limit_reached: false,
        escalation_dismissed: false,
        owner_reviewer_login: "alice",
        escalation_reason: nil,
        draft_review_count: 0,
        review_goal_retry_count: 0,
        pr_followup_count: 0,
        draft: false,
        scan: { triggers: [] }
      }
    end

    def call_service(overrides = {})
      described_class.call(
        project: project,
        issue: issue,
        signals: base_signals.merge(overrides)
      )
    end

    def expect_logged_decision(decision, status:, inputs:, outputs:)
      aggregate_failures do
        expect(decision).to have_attributes(
          project: project,
          decision_type: "escalate",
          actor: "coordination_escalation_service"
        )
        expect(decision.context).to include(
          "issue_id" => issue.id,
          "decision_status" => status
        )
        expect(decision.inputs).to include(inputs)
        expect(decision.outputs).to include(outputs)
      end
    end

    it "escalates on an explicit trigger and records the prediction inputs and outcome" do
      result = call_service(
        operational_failure_breaker: true,
        escalation_reason: "Consecutive operational failures (3 runs)"
      )

      expect(result).to be_escalate
      expect(result.reason).to eq("Consecutive operational failures (3 runs)")
      expect_logged_decision(
        OrchestrationDecision.last,
        status: "applied",
        inputs: {
          "operational_failure_breaker" => true,
          "trigger_types" => [],
          "policy_source" => "feature_orchestration"
        },
        outputs: {
          "decision" => "escalate",
          "reason" => "Consecutive operational failures (3 runs)",
          "explicit_trigger" => "operational_failure_breaker"
        }
      )
    end

    it "defers when the interruption is not worth it yet" do
      result = call_service(followup_limit_reached: true, pr_followup_count: 3)

      expect(result).to be_defer
      expect(result.reason).to eq("followup_limit_reached")
      expect(OrchestrationDecision.last.outputs).to include(
        "decision" => "defer",
        "reason" => "followup_limit_reached"
      )
    end

    it "auto-resolves when automation already reached a terminal non-human outcome" do
      result = call_service(scan: { triggers: [ { type: "owner_approved" } ] })

      expect(result).to be_auto_resolve
      expect(result.reason).to eq("automation_already_resolved")
      expect(OrchestrationDecision.last.outputs).to include(
        "decision" => "auto_resolve",
        "reason" => "automation_already_resolved"
      )
    end

    it "uses account policy overrides when present" do
      create(:orchestration_strategy, :feature_orchestration, :with_account,
        account: project.account,
        configuration: OrchestrationStrategies::Defaults.feature_orchestration.merge(
          "escalation" => {
            "explicit_triggers" => [],
            "human_value_threshold" => 0.15,
            "weights" => {
              "review_goal_retry_pressure" => 0.7,
              "blocking_triggers" => 0.4
            }
          }
        ))

      result = call_service(
        review_goal_retry_count: 3,
        scan: { triggers: [ { type: "ci_failure" }, { type: "merge_conflicts" } ] }
      )

      expect(result).to be_escalate
      expect(result.policy_source).to eq("feature_orchestration")
      expect(result.explicit_trigger).to be_nil
    end
  end
end
