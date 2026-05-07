# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyExperiments::RecordResult do
  let(:strategy_experiment) { create(:strategy_experiment, status: "running", started_at: Time.current) }
  let(:variant) { create(:strategy_experiment_variant, strategy_experiment: strategy_experiment) }
  let(:agent_run) { create(:agent_run) }
  let!(:assignment) do
    create(:strategy_experiment_assignment,
      strategy_experiment: strategy_experiment,
      strategy_experiment_variant: variant,
      agent_run: agent_run)
  end

  it "records a quality score and updates variant aggregates" do
    described_class.call(strategy_experiment: strategy_experiment, agent_run: agent_run, quality_score: 0.85)

    expect(assignment.reload.quality_score.to_f).to eq(0.85)
    expect(variant.reload.sample_count).to eq(1)
    expect(variant.avg_quality_score.to_f).to eq(0.85)
  end

  it "does not double-count repeated recording" do
    described_class.call(strategy_experiment: strategy_experiment, agent_run: agent_run, quality_score: 0.8)
    described_class.call(strategy_experiment: strategy_experiment, agent_run: agent_run, quality_score: 0.9)

    expect(variant.reload.sample_count).to eq(1)
    expect(variant.avg_quality_score.to_f).to eq(0.8)
  end

  it "updates an existing score when update_existing is true" do
    described_class.call(strategy_experiment: strategy_experiment, agent_run: agent_run, quality_score: 0.8)
    described_class.call(
      strategy_experiment: strategy_experiment,
      agent_run: agent_run,
      quality_score: 0.6,
      update_existing: true
    )

    expect(assignment.reload.quality_score.to_f).to eq(0.6)
    expect(variant.reload.sample_count).to eq(1)
    expect(variant.avg_quality_score.to_f).to eq(0.6)
  end

  it "rejects scores outside 0..1" do
    expect {
      described_class.call(strategy_experiment: strategy_experiment, agent_run: agent_run, quality_score: 1.5)
    }.to raise_error(ArgumentError, /between 0 and 1/)
  end
end
