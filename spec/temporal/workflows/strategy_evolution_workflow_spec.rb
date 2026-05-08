# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::StrategyEvolutionWorkflow do
  let(:workflow) { described_class.new }
  let(:input) { { account_id: 9, strategy_type: "review_settings" } }
  let(:prepared_inputs) do
    {
      account_id: 9,
      strategy_type: "review_settings",
      strategy: {
        id: 3,
        strategy_type: "review_settings",
        name: "Review Settings",
        version: 2,
        configuration: OrchestrationStrategies::Defaults.review_settings
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

  it "stops early when history is insufficient" do
    allow(workflow).to receive(:run_activity).and_return(prepared_inputs.deep_merge(performance: { decision_count: 4, min_decisions: 10 }))

    result = workflow.execute(input)

    expect(result).to include(status: :insufficient_history, decision_count: 4, min_decisions: 10)
    expect(workflow).to have_received(:run_activity).once
  end

  it "returns no_mutations when guardrails filter every candidate" do
    allow(workflow).to receive(:run_activity) do |activity_class, *_args|
      case activity_class.name
      when "Activities::PrepareStrategyEvolutionInputsActivity"
        prepared_inputs
      when "Activities::GenerateStrategyMutationsActivity"
        { strategy_type: "review_settings", mutations: [] }
      end
    end

    result = workflow.execute(input)

    expect(result).to include(status: :no_mutations, account_id: 9, strategy_type: "review_settings")
  end

  it "persists generated candidates without auto-promoting them" do
    mutation = {
      configuration: OrchestrationStrategies::Defaults.review_settings.deep_dup,
      strategy: "risk_reduction",
      reasoning: "Safer timeout",
      expected_improvement: "Fewer loops",
      diff: [ { path: "/methods/paid_agent/termination/timeout_minutes", from: 30, to: 20 } ],
      provenance: { source_version: 2 }
    }

    allow(workflow).to receive(:run_activity) do |activity_class, *_args|
      case activity_class.name
      when "Activities::PrepareStrategyEvolutionInputsActivity"
        prepared_inputs
      when "Activities::GenerateStrategyMutationsActivity"
        { strategy_type: "review_settings", mutations: [ mutation ] }
      when "Activities::PersistStrategyCandidatesActivity"
        { strategy_type: "review_settings", candidate_ids: [ 101 ], candidate_count: 1 }
      end
    end

    result = workflow.execute(input)

    expect(result).to include(status: :candidates_created, candidate_ids: [ 101 ], candidate_count: 1)
  end
end
