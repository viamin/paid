# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrchestrationStrategies::Defaults do
  describe ".configuration_for" do
    OrchestrationStrategy::STRATEGY_TYPES.each do |type|
      it "returns a hash for #{type}" do
        config = described_class.configuration_for(type)
        expect(config).to be_a(Hash)
        expect(config).not_to be_empty
      end
    end

    it "returns nil for unknown types" do
      expect(described_class.configuration_for("unknown")).to be_nil
    end
  end

  describe ".review_settings" do
    subject(:config) { described_class.review_settings }

    it "matches Project::DEFAULT_REVIEW_SETTINGS" do
      expect(config).to eq(Project::DEFAULT_REVIEW_SETTINGS)
    end

    it "contains all review methods" do
      expect(config["methods"].keys).to contain_exactly(
        "copilot", "paid_agent", "codex", "ci_action", "manual"
      )
    end
  end

  describe ".quality_gate" do
    subject(:config) { described_class.quality_gate }

    it "matches Project::DEFAULT_QUALITY_GATE_SETTINGS" do
      expect(config).to eq(Project::DEFAULT_QUALITY_GATE_SETTINGS)
    end
  end

  describe ".execution_timeouts" do
    subject(:config) { described_class.execution_timeouts }

    it "preserves the agent timeout default" do
      expect(config["agent_timeout_default_seconds"]).to eq(3600)
    end

    it "preserves issue goal timeout" do
      expect(config["issue_goal_timeout_seconds"]).to eq(
        Activities::RunAgentActivity::DEFAULT_ISSUE_GOAL_TIMEOUT
      )
    end

    it "preserves review goal idle timeout" do
      expect(config["review_goal_idle_timeout_seconds"]).to eq(
        Activities::RunAgentActivity::DEFAULT_REVIEW_GOAL_IDLE_TIMEOUT
      )
    end

    it "preserves feature orchestration timeout" do
      expect(config["feature_orchestration_timeout_seconds"]).to eq(
        Workflows::FeatureOrchestrationWorkflow::DEFAULT_TIMEOUT_SECONDS
      )
    end
  end

  describe ".agent_settings" do
    subject(:config) { described_class.agent_settings }

    it "preserves the default goal from TenantSetting" do
      expect(config["default_goal"]).to eq(
        TenantSetting::DEFAULT_AGENT_SETTINGS["default_goal"]
      )
    end

    it "preserves auto_continue setting" do
      expect(config["auto_continue"]).to eq(
        TenantSetting::DEFAULT_AGENT_SETTINGS["auto_continue"]
      )
    end

    it "preserves guardrail values from TenantSetting" do
      expect(config["guardrails"]["max_concurrent_runs"]).to eq(
        TenantSetting::DEFAULT_GUARDRAILS["max_concurrent_runs"]
      )
    end
  end

  describe ".feature_orchestration" do
    subject(:config) { described_class.feature_orchestration }

    let(:workflow) { Workflows::FeatureOrchestrationWorkflow.allocate }

    it "preserves known failure types" do
      expect(config["known_failure_types"]).to eq(
        Workflows::AgentExecutionWorkflow::KNOWN_FAILURE_TYPES
      )
    end

    it "preserves known failure classes" do
      expect(config["known_failure_classes"]).to eq(
        Workflows::AgentExecutionWorkflow::KNOWN_FAILURE_CLASSES
      )
    end

    it "includes planning phases" do
      expect(config["planning_phases"]).to include("fetch_planning_context", "decompose_feature")
    end

    it "includes escalation policy defaults" do
      expect(config["escalation"]).to include(
        "human_value_threshold",
        "explicit_triggers",
        "weights",
        "interruption_cost"
      )
    end

    it "preserves all planning outcomes returned by the workflow" do
      outcomes = [
        workflow.send(:planning_outcome_for, []),
        workflow.send(:planning_outcome_for, [ { title: "One task" } ]),
        workflow.send(:planning_outcome_for, [ { title: "Task one" }, { title: "Task two" } ]),
        workflow.send(:planning_failure_outcome_for, "decompose_feature"),
        workflow.send(:planning_failure_outcome_for, "create_sub_issues"),
        workflow.send(:planning_failure_outcome_for, "update_planning_labels")
      ]

      expect(config["planning_outcomes"]).to match_array(outcomes.uniq)
    end

    it "preserves all parallelization outcomes returned by the workflow" do
      outcomes = [
        workflow.send(:parallelization_outcome_for, []),
        workflow.send(:parallelization_outcome_for, [ { title: "One task" } ]),
        workflow.send(:parallelization_outcome_for, [ { title: "Task one" }, { title: "Task two" } ]),
        workflow.send(:parallelization_failure_outcome_for, "build_sub_tasks"),
        workflow.send(:parallelization_failure_outcome_for, "run_parallel_execution")
      ]

      expect(config["parallelization_outcomes"]).to match_array(outcomes.uniq)
    end
  end

  describe ".retry_policies" do
    subject(:config) { described_class.retry_policies }

    it "preserves the run_agent retry policy values" do
      policy = Workflows::AgentExecutionWorkflow::RUN_AGENT_RETRY_POLICY

      expect(config["run_agent"]).to eq(
        "max_attempts" => policy.max_attempts,
        "initial_interval_seconds" => policy.initial_interval,
        "max_interval_seconds" => policy.max_interval,
        "backoff_coefficient" => policy.backoff_coefficient
      )
    end
  end

  describe ".provider_resolution" do
    subject(:config) { described_class.provider_resolution }

    it "preserves agent types from AgentRun" do
      expect(config["agent_types"]).to eq(AgentRun::AGENT_TYPES)
    end

    it "preserves goals from AgentRun" do
      expect(config["goals"]).to eq(AgentRun::GOALS)
    end

    it "preserves review method names" do
      expect(config["review_method_names"]).to eq(
        Automation::Configuration::ReviewMethod::NAMES.map(&:to_s)
      )
    end
  end

  describe ".all" do
    it "returns a hash of all strategy types to their configurations" do
      all = described_class.all
      expect(all.keys).to match_array(OrchestrationStrategy::STRATEGY_TYPES)
      all.each_value { |config| expect(config).to be_a(Hash) }
    end
  end
end
