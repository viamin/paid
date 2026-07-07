# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::PersistStrategyCandidatesActivity do
  let(:activity) { described_class.new }
  let(:account) { create(:account) }
  let(:strategy) { create(:orchestration_strategy, :review_settings, account: account, version: 2) }
  let(:input) do
    {
      account_id: account.id,
      strategy: {
        id: strategy.id,
        strategy_type: strategy.strategy_type,
        name: strategy.name,
        version: strategy.version,
        configuration: strategy.configuration
      },
      mutations: [
        {
          configuration: strategy.configuration.deep_dup,
          strategy: "observability",
          reasoning: "Record more context",
          expected_improvement: "Faster diagnosis",
          diff: [ { "path" => "/enabled", "from" => false, "to" => false } ],
          provenance: { "source_version" => strategy.version }
        }
      ]
    }
  end

  before do
    input[:mutations][0][:configuration]["enabled"] = true
    input[:mutations][0][:diff] = [ { "path" => "/enabled", "from" => false, "to" => true } ]
  end

  it "rehydrates mutations with the canonical mutation type" do
    allow(StrategyEvolution::CreateCandidates).to receive(:call).and_return([])

    activity.execute(input)

    expect(StrategyEvolution::CreateCandidates).to have_received(:call) do |kwargs|
      expect(kwargs[:mutations]).to all(be_a(StrategyEvolution::Mutate::Mutation))
    end
  end

  it "persists inactive candidates and returns their ids" do
    result = activity.execute(input)

    expect(result[:candidate_count]).to eq(1)
    expect(result[:candidate_ids]).not_to be_empty
    expect(OrchestrationStrategy.find(result[:candidate_ids].first)).not_to be_active
  end

  it "reuses candidates when retried with identical input" do
    first = activity.execute(input)
    second = activity.execute(input)

    expect(second[:candidate_ids]).to match_array(first[:candidate_ids])
    expect { activity.execute(input) }.not_to change { account.orchestration_strategies.by_type(strategy.strategy_type).count }
  end
end
