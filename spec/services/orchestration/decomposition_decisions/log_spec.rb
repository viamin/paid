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

    it "mirrors the decomposition record into orchestration decisions" do
      described_class.call(**payload)

      orchestration_decision = OrchestrationDecision.find_by(
        project: project,
        decision_type: "planning_outcome",
        actor: "Workflows::PlanningWorkflow"
      )

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
  end
end
