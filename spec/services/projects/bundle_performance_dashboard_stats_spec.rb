# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::BundlePerformanceDashboardStats do
  describe ".call" do
    let(:project) { create(:project) }

    it "returns a sparse payload with no outcomes or experiments" do
      stats = described_class.call(project: project)

      expect(stats[:sparse]).to be(true)
      expect(stats[:bundle_rankings]).to eq([])
      expect(stats[:tradeoff_frontier]).to eq([])
      expect(stats[:experiment_confidence]).to eq([])
    end

    it "summarizes bundle outcomes and optimizer evidence" do
      experiment, control, variant = create_experiment(project:)
      bundle = create_bundle(project:, experiment:, variant:)
      populate_experiment(project:, experiment:, control:, variant:)
      create_bundle_outcomes(project:, bundle:)

      stats = described_class.call(project: project)

      expect(stats[:sparse]).to be(false)
      expect(stats[:summary][:bundle_count]).to eq(1)
      expect(stats[:bundle_rankings].first[:avg_quality_score]).to be_within(0.001).of(0.85)
      expect(stats[:experiment_confidence].first[:variants].size).to eq(2)
      expect(stats[:tradeoff_frontier].first[:bundle]).to eq(bundle)
      expect(stats[:optimizer_insights].find { |row| row[:goal] == "create_pr" }[:candidates]).not_to be_empty
    end
  end

  def create_experiment(project:)
    experiment = create(:configuration_experiment,
      account: project.account,
      status: "running",
      min_samples_per_variant: 2)
    control = create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: experiment.control_value,
      is_control: true,
      sample_count: 2,
      avg_quality_score: 0.5)
    variant = create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(8000),
      sample_count: 2,
      avg_quality_score: 0.82)

    [ experiment, control, variant ]
  end

  def create_bundle(project:, experiment:, variant:)
    create(:configuration_bundle,
      account: project.account,
      definition: {
        "schema_version" => 1,
        "goal" => "create_pr",
        "agent_type" => "claude_code",
        "experiments" => {
          experiment.config_key => {
            "configuration_experiment_id" => experiment.id,
            "configuration_experiment_variant_id" => variant.id,
            "value" => 8000
          }
        }
      })
  end

  def populate_experiment(project:, experiment:, control:, variant:)
    create_assignment(project:, experiment:, variant: control, quality_scores: [ 0.4, 0.5 ])
    create_assignment(project:, experiment:, variant:, quality_scores: [ 0.8, 0.84 ])
  end

  def create_bundle_outcomes(project:, bundle:)
    create_bundle_outcome(project:, bundle:, quality_score: 0.85, cost_cents: 40)
    create_bundle_outcome(project:, bundle:, quality_score: 0.88, cost_cents: 50)
    create_bundle_outcome(project:, bundle:, quality_score: 0.82, cost_cents: 45)
  end

  def create_assignment(project:, experiment:, variant:, quality_scores:)
    quality_scores.each do |score|
      run = create(:agent_run,
        project: project,
        issue: create(:issue, project: project),
        goal: "create_pr")
      create(:configuration_experiment_assignment,
        configuration_experiment: experiment,
        configuration_experiment_variant: variant,
        agent_run: run,
        quality_score: score)
    end
  end

  def create_bundle_outcome(project:, bundle:, quality_score:, cost_cents:)
    run = create(:agent_run,
      :completed,
      project: project,
      issue: create(:issue, project: project),
      goal: "create_pr",
      configuration_bundle: bundle,
      cost_cents: cost_cents)

    create(:bundle_outcome,
      configuration_bundle: bundle,
      agent_run: run,
      quality_score: quality_score,
      cost_cents: cost_cents,
      success: true)
  end
end
