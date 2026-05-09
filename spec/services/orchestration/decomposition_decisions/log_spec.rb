# frozen_string_literal: true

require "rails_helper"

RSpec.describe Orchestration::DecompositionDecisions::Log do
  describe ".call" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project, title: "Add OAuth") }
    let(:payload) do
      {
        project_id: project.id,
        issue_id: issue.id,
        decision_key: "wf-123:planning_outcome:final",
        workflow_name: "Workflows::PlanningWorkflow",
        workflow_id: "wf-123",
        decision_type: "planning_outcome",
        outcome: "sub_issues_created",
        input_context: {
          knowledge_results_count: 2,
          issue_body: "Implement OAuth 2.0"
        },
        plan_data: {
          tasks: [
            { index: 0, title: "Schema", dependencies: [], parallel_group: 0 },
            { index: 1, title: "Model", dependencies: [ 0 ], parallel_group: 1 },
            { index: 2, title: "Controller", dependencies: [], parallel_group: 0 }
          ],
          created_issues: [
            { github_number: 101 },
            { github_number: 102 }
          ]
        },
        error_details: {},
        metadata: {
          prompt_source: "fallback_prompt",
          activity_boundaries: [ "Activities::DecomposeFeatureActivity" ]
        }
      }
    end

    before { Strategies::SeedBaselineOrchestration.call }

    def orchestration_decision_for(decision_key, decision_type: "planning_outcome")
      OrchestrationDecision.find_by!(
        [
          <<~SQL.squish,
            project_id = ?
            AND decision_type = ?
            AND actor = ?
            AND context ->> 'decision_key' = ?
          SQL
          project.id,
          decision_type,
          "Workflows::PlanningWorkflow",
          decision_key
        ]
      )
    end

    def baseline_strategy_version_for(decision_type)
      Strategies::ResolveVersion.call(
        slug: Strategies::BaselineOrchestration.slug_for_decision_type(decision_type),
        project: project
      )
    end

    it "persists structured context, plan data, and derived hints" do
      decision = described_class.call(**payload)

      expect(decision).to be_persisted
      expect(decision.input_context).to include(
        "knowledge_results_count" => 2,
        "issue" => include(
          "id" => issue.id,
          "github_number" => issue.github_number,
          "title" => "Add OAuth"
        )
      )
      expect(decision.plan_data["tasks"].size).to eq(3)
      expect(decision.hints).to include(
        "task_count" => 3,
        "created_issue_count" => 2,
        "dependency_edges" => 1,
        "tasks_with_dependencies" => 1,
        "created_issue_numbers" => [ 101, 102 ]
      )
      expect(decision.hints["parallelizable_groups"]).to eq({ "0" => [ 0, 2 ] })
      expect(decision.metadata["prompt_source"]).to eq("fallback_prompt")
    end

    it "persists decomposition strategy decisions with workflow context" do
      decision = described_class.call(**payload.merge(
        decision_key: "wf-123:decomposition_strategy:final",
        decision_type: "decomposition_strategy",
        outcome: "llm_fallback_after_policy_failure",
        metadata: payload[:metadata].merge(
          workflow_step: "decompose_feature",
          policy_source: "experiment",
          policy_error: { error_message: "scope failure" }
        )
      ))

      expect(decision.decision_type).to eq("decomposition_strategy")
      expect(decision.metadata).to include(
        "workflow_step" => "decompose_feature",
        "policy_source" => "experiment",
        "policy_error" => include("error_message" => "scope failure")
      )
      expect(decision.hints).to include(
        "task_count" => 3,
        "dependency_edges" => 1
      )
    end

    it "mirrors the decomposition record into orchestration decisions" do
      described_class.call(**payload)

      orchestration_decision = orchestration_decision_for(payload[:decision_key])

      expect(orchestration_decision).to be_present
      expect(orchestration_decision.context).to include(
        "decision_key" => payload[:decision_key],
        "workflow_id" => payload[:workflow_id],
        "decision_status" => "applied"
      )
      expect(orchestration_decision.inputs).to include(
        "knowledge_results_count" => 2,
        "issue" => include("id" => issue.id, "title" => "Add OAuth")
      )
      expect(orchestration_decision.outputs).to include(
        "outcome" => "sub_issues_created",
        "hints" => include("task_count" => 3)
      )
      expect(orchestration_decision.strategy_version).to eq(baseline_strategy_version_for("planning_outcome"))
    end

    it "marks skipped decomposition outcomes as noop" do
      decision_key = "wf-123:planning_outcome:single-task"
      described_class.call(**payload.merge(
        decision_key: decision_key,
        outcome: "single_task_plan",
        plan_data: { tasks: [ { index: 0, title: "Only task", dependencies: [], parallel_group: 0 } ] }
      ))
      orchestration_decision = orchestration_decision_for(decision_key)

      expect(orchestration_decision.context["decision_status"]).to eq("noop")
      expect(orchestration_decision.outputs["outcome"]).to eq("single_task_plan")
    end

    it "marks policy-skipped decomposition strategy outcomes as noop" do
      decision_key = "wf-123:decomposition_strategy:policy-skipped"
      described_class.call(**payload.merge(
        decision_key: decision_key,
        decision_type: "decomposition_strategy",
        outcome: "policy_skipped"
      ))
      orchestration_decision = orchestration_decision_for(
        decision_key,
        decision_type: "decomposition_strategy"
      )

      expect(orchestration_decision.context["decision_status"]).to eq("noop")
      expect(orchestration_decision.outputs["outcome"]).to eq("policy_skipped")
    end

    it "marks failed decomposition outcomes as failed" do
      decision_key = "wf-123:planning_outcome:failed"
      described_class.call(**payload.merge(
        decision_key: decision_key,
        outcome: "decomposition_failed",
        error_details: { error_message: "LLM failed" }
      ))
      orchestration_decision = orchestration_decision_for(decision_key)

      expect(orchestration_decision.context["decision_status"]).to eq("failed")
      expect(orchestration_decision.outputs["error_details"]).to include("error_message" => "LLM failed")
    end

    it "is idempotent on decision_key" do
      first = described_class.call(**payload)
      second = described_class.call(**payload)

      expect(second.id).to eq(first.id)
      expect(DecompositionDecision.where(decision_key: payload[:decision_key]).count).to eq(1)
      expect(
        OrchestrationDecision.where(
          project: project,
          decision_type: "planning_outcome",
          actor: "Workflows::PlanningWorkflow"
        ).count
      ).to eq(1)
    end

    it "does not mask the decomposition decision when orchestration mirroring fails" do
      allow(OrchestrationDecision).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
      allow(Rails.logger).to receive(:warn)

      decision = described_class.call(**payload)

      expect(decision).to be_persisted
      expect(decision.decision_key).to eq(payload[:decision_key])
      expect(DecompositionDecision.find_by(decision_key: payload[:decision_key])).to eq(decision)
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "decomposition.orchestration_decision_failed",
          project_id: project.id,
          decision_key: payload[:decision_key],
          error_class: "ActiveRecord::StatementInvalid",
          error: "boom"
        )
      )
    end
  end
end
