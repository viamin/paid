# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicyEvolution::PrepareInputs do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let!(:policy) do
      create(:coordination_policy, :active,
        account: account,
        policy_type: described_class::POLICY_TYPE,
        policy_key: described_class::POLICY_KEY,
        name: "Feature Decomposition").tap do |record|
          record.current_version.update!(
            version: 2,
            rules: { "enabled" => true, "min_components_to_decompose" => 2 },
            parameters: { "max_tasks" => 12 }
          )
          create(:coordination_policy_version,
            coordination_policy: record,
            version: 1,
            status: "superseded",
            rules: { "enabled" => true, "min_components_to_decompose" => 3 },
            parameters: { "max_tasks" => 8 })
        end
    end
    let(:result) { described_class.call(account: account, min_decisions: 2) }

    before do
      create(
        :decomposition_decision,
        project: project,
        issue: create(:issue, project: project),
        decision_type: "planning_outcome",
        outcome: "sub_issues_created",
        hints: { "task_count" => 3 },
        metadata: { "policy_source" => "feature_orchestration" }
      )
      create(
        :decomposition_decision,
        project: project,
        issue: create(:issue, project: project),
        decision_type: "parallelization_outcome",
        outcome: "parallelization_failed",
        hints: { "task_count" => 2 },
        error_details: { "type" => "DependencyCycle" },
        metadata: { "policy_source" => "defaults" }
      )
      create(
        :decomposition_decision,
        project: project,
        issue: create(:issue, project: project),
        decision_type: "planning_outcome",
        outcome: "empty_plan",
        hints: { "task_count" => 0 },
        metadata: { "policy_source" => "feature_orchestration" }
      )
      create(
        :decomposition_decision,
        project: project,
        issue: create(:issue, project: project),
        decision_type: "decomposition_strategy",
        outcome: "decomposed",
        hints: { "task_count" => 99 },
        metadata: { "policy_source" => "feature_orchestration" }
      )
      other_project = create(:project)
      create(:decomposition_decision, project: other_project, issue: create(:issue, project: other_project))
    end

    it "collects policy history for the account" do
      expect(result[:policy]).to include(id: policy.id, version: 2, policy_type: "decomposition")
      expect(result[:prior_versions].map { |row| row[:id] }).to include(policy.current_version.id)
    end

    it "summarizes classified outcomes without counting noop decisions as successes" do
      expect(result.dig(:performance, :decision_count)).to eq(3)
      expect(result.dig(:performance, :classified_decision_count)).to eq(2)
      expect(result.dig(:performance, :success_count)).to eq(1)
      expect(result.dig(:performance, :failure_count)).to eq(1)
      expect(result.dig(:performance, :noop_count)).to eq(1)
      expect(result.dig(:performance, :success_rate)).to eq(0.5)
    end

    it "reports SQL-backed aggregate metrics and samples" do
      expect(result.dig(:performance, :decision_type_counts)).to include(
        "planning_outcome" => 2,
        "parallelization_outcome" => 1
      )
      expect(result.dig(:performance, :decision_type_counts)).not_to include("decomposition_strategy")
      expect(result.dig(:performance, :policy_source_counts)).to include(
        "feature_orchestration" => 2,
        "defaults" => 1
      )
      expect(result.dig(:performance, :average_task_count)).to eq(1.67)
      expect(result[:sample_successes].size).to eq(1)
      expect(result[:sample_failures].size).to eq(1)
    end

    it "includes effective policy configuration for mutation" do
      expect(result.dig(:policy, :configuration, "decomposition")).to include(
        "enabled" => true,
        "min_components_to_decompose" => 2,
        "max_tasks" => 12
      )
    end

    context "with recovery policy evolution inputs" do
      let!(:recovery_policy) do
        create(:coordination_policy, :active,
          account: account,
          policy_type: "recovery",
          policy_key: Coordination::FailureRecoveryPolicy::POLICY_KEY,
          name: "Failure Recovery").tap do |record|
            record.current_version.update!(
              version: 2,
              rules: { "failure_actions" => { "timeout" => "retry_same_provider" } },
              parameters: { "default_action" => "pause_and_notify" }
            )
          end
      end
      let(:recovery_result) { described_class.call(account: account, policy_type: "recovery", min_decisions: 2) }

      before do
        create(:orchestration_decision,
          project: project,
          decision_type: "retry",
          actor: "coordination_failure_recovery",
          context: { "decision_status" => "applied" },
          inputs: { "policy_source" => "coordination_policy" },
          outputs: { "chosen_action" => "retry_same_provider" })
        create(:orchestration_decision,
          project: project,
          decision_type: "pause",
          actor: "coordination_failure_recovery",
          context: { "decision_status" => "failed" },
          inputs: { "policy_source" => "defaults" },
          outputs: { "chosen_action" => "pause_and_notify" })
      end

      it "supports recovery policy snapshots and orchestration decision metrics" do
        expect(recovery_result[:policy]).to include(id: recovery_policy.id, policy_type: "recovery")
        expect(recovery_result.dig(:policy, :configuration, "recovery")).to include(
          "actions" => include("timeout" => "retry_same_provider"),
          "default_action" => "pause_and_notify"
        )
        expect(recovery_result.dig(:performance, :decision_count)).to eq(2)
        expect(recovery_result.dig(:performance, :classified_decision_count)).to eq(2)
        expect(recovery_result.dig(:performance, :failure_count)).to eq(1)
        expect(recovery_result.dig(:performance, :policy_source_counts)).to include(
          "coordination_policy" => 1,
          "defaults" => 1
        )
      end
    end

    context "with escalation policy evolution inputs" do
      let(:escalation_result) { described_class.call(account: account, policy_type: "escalation", min_decisions: 1) }

      before do
        create(:orchestration_decision,
          project: project,
          decision_type: "escalate",
          actor: "coordination_escalation_service",
          context: { "decision_status" => "applied" },
          inputs: { "policy_source" => "defaults" },
          outputs: { "human_value_score" => 0.9 })
      end

      it "supports escalation bootstrap policies without a persisted coordination policy" do
        expect(escalation_result[:policy]).to include(
          policy_type: "escalation",
          policy_key: Coordination::EscalationPolicy::POLICY_KEY,
          source: "defaults"
        )
        expect(escalation_result.dig(:policy, :configuration, "escalation")).to include(
          "human_value_threshold",
          "explicit_triggers",
          "weights",
          "interruption_cost"
        )
        expect(escalation_result.dig(:performance, :decision_type_counts)).to include("escalate" => 1)
      end
    end
  end
end
