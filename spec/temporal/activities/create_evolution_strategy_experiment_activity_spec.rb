# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateEvolutionStrategyExperimentActivity do
  let(:activity) { described_class.new }
  let(:account) { create(:account) }
  let(:control_strategy) { create(:orchestration_strategy, :review_settings, account: account, version: 2) }
  let!(:candidate_strategy) { create(:orchestration_strategy, :review_settings, account: account, version: 3, active: false) }
  let(:input) do
    {
      account_id: account.id,
      strategy: StrategyExperiments::StrategySnapshot.serialize(control_strategy),
      candidate_ids: [ candidate_strategy.id ],
      min_samples_per_variant: 15,
      confidence_threshold: 0.9
    }
  end

  it "creates and starts a strategy experiment for the candidates" do
    result = activity.execute(input)

    expect(result[:status]).to eq(:created)
    experiment = StrategyExperiment.find(result[:strategy_experiment_id])
    expect(experiment).to be_running
    expect(experiment.strategy_name).to eq("review_settings")
    expect(experiment.strategy_experiment_variants.count).to eq(2)
  end

  it "returns an existing running experiment for the same strategy" do
    existing = StrategyExperiments::CreateForCandidates.call(
      account: account,
      strategy_type: "review_settings",
      control_strategy: control_strategy,
      candidate_strategies: [ candidate_strategy ]
    )
    existing.start!

    result = activity.execute(input)

    expect(result).to eq(
      strategy_experiment_id: existing.id,
      status: :already_running
    )
  end
end
