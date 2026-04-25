# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationExperiments::RecordResult do
  let(:configuration_experiment) { create(:configuration_experiment, status: "running", started_at: Time.current) }
  let(:variant) { create(:configuration_experiment_variant, configuration_experiment: configuration_experiment) }
  let(:agent_run) { create(:agent_run) }
  let!(:assignment) do
    create(:configuration_experiment_assignment,
      configuration_experiment: configuration_experiment,
      configuration_experiment_variant: variant,
      agent_run: agent_run)
  end

  it "records a quality score and updates variant aggregates" do
    described_class.call(configuration_experiment: configuration_experiment, agent_run: agent_run, quality_score: 0.85)

    expect(assignment.reload.quality_score.to_f).to eq(0.85)
    expect(variant.reload.sample_count).to eq(1)
    expect(variant.avg_quality_score.to_f).to eq(0.85)
  end

  it "does not double-count repeated recording" do
    described_class.call(configuration_experiment: configuration_experiment, agent_run: agent_run, quality_score: 0.8)
    described_class.call(configuration_experiment: configuration_experiment, agent_run: agent_run, quality_score: 0.9)

    expect(variant.reload.sample_count).to eq(1)
    expect(variant.avg_quality_score.to_f).to eq(0.8)
  end

  it "updates an existing score and adjusts aggregates when update_existing is true" do
    described_class.call(configuration_experiment: configuration_experiment, agent_run: agent_run, quality_score: 0.8)
    described_class.call(
      configuration_experiment: configuration_experiment,
      agent_run: agent_run,
      quality_score: 0.6,
      update_existing: true
    )

    expect(assignment.reload.quality_score.to_f).to eq(0.6)
    expect(variant.reload.sample_count).to eq(1)
    expect(variant.avg_quality_score.to_f).to eq(0.6)
  end

  it "forces reanalysis when update_existing replaces a score on a sufficiently-sampled experiment" do
    # Create a second variant so the experiment has enough structure
    other_variant = create(:configuration_experiment_variant, configuration_experiment: configuration_experiment)
    other_run = create(:agent_run)
    create(:configuration_experiment_assignment,
      configuration_experiment: configuration_experiment,
      configuration_experiment_variant: other_variant,
      agent_run: other_run)

    # Record initial scores
    described_class.call(configuration_experiment: configuration_experiment, agent_run: agent_run, quality_score: 0.8)
    described_class.call(configuration_experiment: configuration_experiment, agent_run: other_run, quality_score: 0.5)

    # Cache an analysis result
    configuration_experiment.reload
    configuration_experiment.update_columns(cached_analysis: { status: "stale" }.to_json, analysis_samples_key: "old")

    # Update a score — should clear and recompute analysis
    described_class.call(
      configuration_experiment: configuration_experiment,
      agent_run: agent_run,
      quality_score: 0.9,
      update_existing: true
    )

    configuration_experiment.reload
    # The stale cached_analysis should have been cleared and recomputed
    expect(configuration_experiment.cached_analysis).not_to eq({ status: "stale" }.to_json)
  end
end
