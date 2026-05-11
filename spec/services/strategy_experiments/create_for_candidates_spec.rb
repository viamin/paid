# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyExperiments::CreateForCandidates do
  describe ".call" do
    let(:account) { create(:account) }
    let(:control_strategy) { create(:orchestration_strategy, :review_settings, account: account, version: 2) }
    let(:candidate_strategy) { create(:orchestration_strategy, :review_settings, account: account, version: 3, active: false) }

    it "creates a strategy experiment from orchestration strategy snapshots" do
      experiment = described_class.call(
        account: account,
        strategy_type: "review_settings",
        control_strategy: control_strategy,
        candidate_strategies: [ candidate_strategy ],
        min_samples_per_variant: 12,
        confidence_threshold: 0.9
      )

      expect(experiment.strategy_name).to eq("review_settings")
      expect(experiment.min_samples_per_variant).to eq(12)
      expect(experiment.confidence_threshold.to_f).to eq(0.9)
      expect(experiment.control_variant.parsed_config).to include(
        "id" => control_strategy.id,
        "version" => control_strategy.version
      )
      expect(experiment.strategy_experiment_variants.find_by(is_control: false).parsed_config).to include(
        "id" => candidate_strategy.id,
        "version" => candidate_strategy.version
      )
    end

    it "rejects candidate strategies for a different type" do
      wrong_type = create(:orchestration_strategy, :quality_gate, account: account, active: false)

      expect {
        described_class.call(
          account: account,
          strategy_type: "review_settings",
          control_strategy: control_strategy,
          candidate_strategies: [ wrong_type ]
        )
      }.to raise_error(ArgumentError, /match the experiment strategy type/)
    end
  end
end
