# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::ObjectiveScore, :no_db do
  describe ".from_outcome" do
    it "returns the stored objective score when metrics already include it" do
      outcome = double(metrics: { "objective_score" => "0.72" })

      expect(described_class.from_outcome(outcome)).to eq(0.72)
    end

    it "computes the objective score from the outcome when metrics are missing it" do
      project = double(fitness_settings: nil)
      agent_run = double(project: project)
      outcome = double(
        metrics: nil,
        agent_run: agent_run,
        quality_score: 0.8,
        cost_cents: 50,
        duration_seconds: 600)

      expect(described_class.from_outcome(outcome)).to be_within(0.001).of(0.7133)
    end
  end

  it "returns a cost-aware objective and a measurable quality-per-dollar ratio" do
    project = double(fitness_settings: nil)

    result = described_class.call(
      project: project,
      quality_score: 0.8,
      cost_cents: 50,
      duration_seconds: 600
    )

    expect(result.objective_score).to be_within(0.001).of(0.7133)
    expect(result.cost_score).to be_within(0.001).of(0.6667)
    expect(result.speed_score).to be_within(0.001).of(0.5)
    expect(result.quality_per_dollar).to be_within(0.001).of(1.6)
  end

  it "respects optimizer-specific weights and references from project settings" do
    project = double(fitness_settings: {
      "configuration_bundle_optimizer" => {
        "weights" => { "quality" => 1.0, "cost" => 0.0, "speed" => 0.0 },
        "reference_cost_cents" => 500,
        "reference_duration_seconds" => 1200
      }
    })

    result = described_class.call(
      project: project,
      quality_score: 0.8,
      cost_cents: 500,
      duration_seconds: 1200
    )

    expect(result.objective_score).to eq(0.8)
    expect(result.cost_score).to be_within(0.001).of(0.5)
    expect(result.speed_score).to be_within(0.001).of(0.5)
  end
end
