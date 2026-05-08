# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::CoordinationPolicyEvolutionWorkflow do
  let(:workflow) { described_class.new }
  let(:input) { { account_id: 9 } }
  let(:mutation) do
    {
      configuration: OrchestrationStrategies::Defaults.feature_orchestration.deep_dup,
      strategy: "risk_reduction",
      reasoning: "Safer coordination",
      expected_improvement: "Fewer planning failures",
      diff: [ { path: "/decomposition/max_tasks", from: 20, to: 12 } ],
      provenance: { sampled_decision_ids: [ 101 ] }
    }
  end
  let(:prepared_inputs) do
    {
      account_id: 9,
      policy_type: "feature_orchestration",
      strategy: {
        id: 3,
        strategy_type: "feature_orchestration",
        name: "Feature Orchestration",
        version: 2,
        configuration: OrchestrationStrategies::Defaults.feature_orchestration
      },
      prior_versions: [],
      performance: { decision_count: 12, min_decisions: 10 },
      sample_successes: [],
      sample_failures: []
    }
  end

  before do
    allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger)
  end

  it "stops early when coordination history is insufficient" do
    allow(workflow).to receive(:run_activity).and_return(prepared_inputs.deep_merge(performance: { decision_count: 4, min_decisions: 10 }))

    result = workflow.execute(input)

    expect(result).to include(status: :insufficient_history, decision_count: 4, min_decisions: 10)
    expect(workflow).to have_received(:run_activity).once
  end

  it "persists generated policy candidates without promoting them" do
    allow(workflow).to receive(:run_activity) do |activity_class, *_args|
      case activity_class.name
      when "Activities::PrepareCoordinationPolicyEvolutionInputsActivity"
        prepared_inputs
      when "Activities::GenerateCoordinationPolicyCandidatesActivity"
        { policy_type: "feature_orchestration", mutations: [ mutation ] }
      when "Activities::PersistCoordinationPolicyCandidatesActivity"
        { policy_type: "feature_orchestration", candidate_ids: [ 101 ], candidate_count: 1 }
      end
    end

    result = workflow.execute(input)

    expect(result).to include(
      status: :candidates_created,
      policy_type: "feature_orchestration",
      candidate_ids: [ 101 ],
      candidate_count: 1
    )
  end
end
