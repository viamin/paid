# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyExperiments::Create do
  describe ".call" do
    let(:account) { create(:account) }

    it "creates a draft experiment with control and variant configs" do
      experiment = described_class.call(
        account: account,
        name: "Auto-review evolved v2",
        strategy_name: "auto_review",
        control_config: { "version" => "baseline" },
        variant_configs: [ { "version" => "evolved_v2" } ]
      )

      expect(experiment).to be_persisted
      expect(experiment.account).to eq(account)
      expect(experiment.status).to eq("draft")
      expect(experiment.strategy_name).to eq("auto_review")
      expect(experiment.strategy_experiment_variants.size).to eq(2)
      expect(experiment.control_variant.parsed_config).to eq("version" => "baseline")
    end

    it "rejects duplicate variant configs" do
      expect {
        described_class.call(
          account: account,
          name: "Dup test",
          strategy_name: "auto_pick",
          control_config: { "v" => 1 },
          variant_configs: [ { "v" => 2 }, { "v" => 2 } ]
        )
      }.to raise_error(ArgumentError, /unique/)
    end

    it "rejects variant configs matching the control" do
      expect {
        described_class.call(
          account: account,
          name: "Same as control",
          strategy_name: "auto_pick",
          control_config: { "v" => 1 },
          variant_configs: [ { "v" => 1 } ]
        )
      }.to raise_error(ArgumentError, /control/)
    end

    it "rejects empty variant configs" do
      expect {
        described_class.call(
          account: account,
          name: "No variants",
          strategy_name: "auto_pick",
          control_config: { "v" => 1 },
          variant_configs: []
        )
      }.to raise_error(ArgumentError, /at least one/)
    end
  end

  describe "full lifecycle: create, assign, record, auto-complete" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "auto-completes with the evolved variant as winner" do
      experiment = described_class.call(
        account: account,
        name: "Auto-review evolved v2 test",
        strategy_name: "auto_review",
        control_config: { "version" => "baseline" },
        variant_configs: [ { "version" => "evolved_v2" } ],
        min_samples_per_variant: 5,
        confidence_threshold: 0.95
      )

      control = experiment.control_variant
      variant = experiment.strategy_experiment_variants.find_by(is_control: false)
      experiment.start!

      record_scores(experiment, control, project, [ 0.3, 0.35, 0.25, 0.3, 0.28 ])
      record_scores(experiment, variant, project, [ 0.8, 0.85, 0.9, 0.82, 0.88 ])

      experiment.reload
      expect(experiment.status).to eq("completed")
      expect(experiment.winner_variant).to eq(variant)
    end

    it "distributes assignments across variants" do
      experiment = described_class.call(
        account: account,
        name: "Balanced test",
        strategy_name: "auto_pick",
        control_config: { "v" => 1 },
        variant_configs: [ { "v" => 2 } ],
        min_samples_per_variant: 5
      )
      experiment.start!

      counts = 10.times
        .map { StrategyExperiments::Assign.call(strategy_experiment: experiment, agent_run: create(:agent_run, project: project)) }
        .map(&:strategy_experiment_variant_id)
        .tally

      expect(counts.keys.size).to eq(2)
      counts.each_value { |c| expect(c).to be >= 2 }
    end

    private

    def record_scores(experiment, variant, project, scores)
      scores.each do |score|
        run = create(:agent_run, project: project)
        StrategyExperimentAssignment.create!(
          strategy_experiment: experiment,
          strategy_experiment_variant: variant,
          agent_run: run
        )
        StrategyExperiments::RecordResult.call(
          strategy_experiment: experiment,
          agent_run: run,
          quality_score: score
        )
      end
    end
  end
end
