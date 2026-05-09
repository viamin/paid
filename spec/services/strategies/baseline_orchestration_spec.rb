# frozen_string_literal: true

require "rails_helper"

RSpec.describe Strategies::BaselineOrchestration do
  describe ".definitions" do
    it "defines one global baseline strategy per decomposition decision type" do
      expect(described_class.definitions.map { |definition| definition[:decision_type] }).to contain_exactly(
        "decomposition_strategy",
        "planning_outcome",
        "parallelization_outcome"
      )
    end
  end

  describe ".decomposition_strategy" do
    subject(:content) { described_class.decomposition_strategy }

    it "preserves policy-based decomposition defaults" do
      expect(content.dig("policy_service", "strategy_type")).to eq(Coordination::DecompositionService::STRATEGY_TYPE)
      expect(content.dig("policy_service", "default_policy")).to eq(Coordination::DecompositionService::DEFAULT_POLICY)
      expect(content.dig("policy_service", "prompt_source")).to eq(Activities::DecomposeFeatureActivity::POLICY_PROMPT_SOURCE)
    end

    it "preserves the fallback LLM decomposition settings" do
      expect(content.dig("llm_fallback", "prompt_slug")).to eq(Activities::DecomposeFeatureActivity::PROMPT_SLUG)
      expect(content.dig("llm_fallback", "model")).to eq(Activities::DecomposeFeatureActivity::DEFAULT_MODEL)
      expect(content.dig("llm_fallback", "timeout_seconds")).to eq(Activities::DecomposeFeatureActivity::TIMEOUT)
      expect(content.dig("llm_fallback", "max_tasks")).to eq(Activities::DecomposeFeatureActivity::MAX_TASKS)
    end
  end

  describe ".planning_outcome" do
    subject(:content) { described_class.planning_outcome }

    let(:workflow) { Workflows::PlanningWorkflow.allocate }

    it "preserves planning steps" do
      expect(content["steps"]).to eq(%w[
        fetch_planning_context
        decompose_feature
        create_sub_issues
        update_planning_labels
      ])
    end

    it "preserves success outcome mappings" do
      expect(content["success_outcomes"]).to match_array([
        workflow.send(:planning_outcome_for, []),
        workflow.send(:planning_outcome_for, [ { title: "One task" } ]),
        workflow.send(:planning_outcome_for, [ { title: "Task one" }, { title: "Task two" } ])
      ].uniq)
    end

    it "preserves failure outcome mappings" do
      expect(content["failure_outcomes"]).to eq(
        "decompose_feature" => workflow.send(:planning_failure_outcome_for, "decompose_feature"),
        "create_sub_issues" => workflow.send(:planning_failure_outcome_for, "create_sub_issues"),
        "update_planning_labels" => workflow.send(:planning_failure_outcome_for, "update_planning_labels")
      )
    end
  end

  describe ".parallelization_outcome" do
    subject(:content) { described_class.parallelization_outcome }

    let(:workflow) { Workflows::FeatureOrchestrationWorkflow.allocate }

    it "preserves timeout and child workflow defaults" do
      expect(content["default_timeout_seconds"]).to eq(Workflows::FeatureOrchestrationWorkflow::DEFAULT_TIMEOUT_SECONDS)
      expect(content["minimum_parallel_task_count"]).to eq(2)
      expect(content["child_workflow"]).to eq("Workflows::ParallelAgentExecutionWorkflow")
    end

    it "preserves success outcome mappings" do
      expect(content["success_outcomes"]).to match_array([
        workflow.send(:parallelization_outcome_for, []),
        workflow.send(:parallelization_outcome_for, [ { title: "One task" } ]),
        workflow.send(:parallelization_outcome_for, [ { title: "Task one" }, { title: "Task two" } ]),
        "parallel_execution_planned"
      ].uniq)
    end

    it "preserves failure outcome mappings" do
      expect(content["failure_outcomes"]).to eq(
        "build_sub_tasks" => workflow.send(:parallelization_failure_outcome_for, "build_sub_tasks"),
        "run_parallel_execution" => workflow.send(:parallelization_failure_outcome_for, "run_parallel_execution")
      )
    end
  end

  describe ".slug_for_decision_type" do
    it "maps decomposition decision types to baseline strategy slugs" do
      expect(described_class.slug_for_decision_type("decomposition_strategy")).to eq(described_class::DECOMPOSITION_STRATEGY_SLUG)
      expect(described_class.slug_for_decision_type("planning_outcome")).to eq(described_class::PLANNING_OUTCOME_SLUG)
      expect(described_class.slug_for_decision_type("parallelization_outcome")).to eq(described_class::PARALLELIZATION_OUTCOME_SLUG)
      expect(described_class.slug_for_decision_type("unknown")).to be_nil
    end
  end
end
