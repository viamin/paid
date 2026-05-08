# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::GenerateStrategyMutationsActivity do
  let(:activity) { described_class.new }
  let(:strategy) do
    {
      id: 3,
      strategy_type: "review_settings",
      name: "Review Settings",
      version: 2,
      account_id: 9,
      configuration: OrchestrationStrategies::Defaults.review_settings
    }
  end
  let(:mutation) do
    StrategyEvolution::Mutate::Mutation.new(
      configuration: strategy[:configuration],
      strategy: "refinement",
      reasoning: "Tune review flow",
      expected_improvement: "Higher success rate",
      diff: [ { "path" => "/enabled", "from" => false, "to" => true } ],
      provenance: { "source_version" => 2 }
    )
  end

  it "serializes generated mutations" do
    allow(StrategyEvolution::Mutate).to receive(:call).and_return([ mutation ])

    result = activity.execute(
      strategy: strategy,
      performance: { decision_count: 12 },
      sample_successes: [],
      sample_failures: [],
      mutation_count: 1
    )

    expect(result[:mutations]).to contain_exactly(
      include(strategy: "refinement", expected_improvement: "Higher success rate")
    )
  end
end
