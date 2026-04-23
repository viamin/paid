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
end
