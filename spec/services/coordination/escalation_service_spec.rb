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
        failure_streak_limit_reached: false,
        escalation_dismissed: false,
        owner_reviewer_login: "alice",
        escalation_reason: nil,
        consecutive_unsuccessful_automatic_runs: 0,
        consecutive_operational_failures: 0,
        last_meaningful_progress_at: nil,
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

    def persisted_prediction_signals
      {
        "operational_failure_breaker" => true,
        "unified_failure_pressure" => 0.0,
        "blocking_trigger_pressure" => 0.0,
        "owner_reviewer_present" => true,
        "escalated_phase" => false
      }
    end

    def create_escalation_policy!(scope: :account, rules: {}, parameters: {})
      traits = [ :active ]
      traits << :project_scoped if scope == :project

      create(:coordination_policy, *traits,
        account: project.account,
        project: scope == :project ? project : nil,
        policy_type: "escalation",
        policy_key: Coordination::EscalationPolicy::POLICY_KEY).tap do |policy|
        policy.current_version.update!(rules:, parameters:)
      end
    end

    def explicit_trigger_decision_inputs
      {
        "operational_failure_breaker" => true,
        "prediction_signals" => persisted_prediction_signals,
        "trigger_types" => [],
        "policy_source" => "defaults",
        "policy_key" => "human_intervention"
      }
    end

    def coordination_policy_version_inputs(policy)
      {
        "policy_source" => "coordination_policy",
        "coordination_policy_id" => policy.id,
        "coordination_policy_version_id" => policy.current_version.id,
        "coordination_policy_version" => policy.current_version.version
      }
    end

    def low_threshold_parameters
      {
        "human_value_threshold" => 0.15,
        "weights" => {
          "unified_failure_pressure" => 0.7,
          "blocking_triggers" => 0.4
        }
      }
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
        inputs: explicit_trigger_decision_inputs,
        outputs: {
          "decision" => "escalate",
          "reason" => "Consecutive operational failures (3 runs)",
          "explicit_trigger" => "operational_failure_breaker",
          "policy_source" => "defaults"
        }
      )
    end

    it "auto-resolves when no explicit trigger and no strong retry pressure exist" do
      result = call_service

      expect(result).to be_auto_resolve
      expect(result.reason).to eq("automation_can_finish_without_human")
      expect(OrchestrationDecision.last.outputs).to include(
        "decision" => "auto_resolve",
        "reason" => "automation_can_finish_without_human",
        "policy_source" => "defaults"
      )
    end

    it "auto-resolves when automation already reached a terminal non-human outcome" do
      result = call_service(scan: { triggers: [ { type: "owner_approved" } ] })

      expect(result).to be_auto_resolve
      expect(result.reason).to eq("automation_already_resolved")
      expect(OrchestrationDecision.last.outputs).to include(
        "decision" => "auto_resolve",
        "reason" => "automation_already_resolved",
        "policy_source" => "defaults"
      )
    end

    it "uses the active coordination policy when present" do
      policy = create_escalation_policy!(
        rules: { "explicit_triggers" => [] },
        parameters: low_threshold_parameters)

      result = call_service(
        consecutive_unsuccessful_automatic_runs: 3,
        scan: { triggers: [ { type: "ci_failure" }, { type: "merge_conflicts" } ] }
      )

      expect(result).to be_escalate
      expect(result.policy_source).to eq("coordination_policy")
      expect(result.explicit_trigger).to be_nil
      expect(OrchestrationDecision.last.inputs).to include(coordination_policy_version_inputs(policy))
    end

    it "prefers a project-scoped coordination policy over an account-wide policy" do
      create_escalation_policy!(
        rules: { "explicit_triggers" => [] },
        parameters: { "human_value_threshold" => 0.05 }
      )
      scoped_policy = create_escalation_policy!(scope: :project,
        rules: { "explicit_triggers" => [] },
        parameters: { "human_value_threshold" => 0.9 })

      result = call_service(consecutive_unsuccessful_automatic_runs: 3)

      expect(result).to be_auto_resolve
      expect(OrchestrationDecision.last.inputs).to include(
        "coordination_policy_id" => scoped_policy.id,
        "coordination_policy_version_id" => scoped_policy.current_version.id
      )
    end
  end
end
