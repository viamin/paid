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

    it "computes summary counts from all bundles, not just the displayed rows" do
      Array.new(12) do
        bundle = create(:configuration_bundle, account: project.account, definition: {
          "schema_version" => 1, "goal" => "create_pr", "agent_type" => "claude_code", "experiments" => {}
        })
        3.times { create_bundle_outcome(project: project, bundle: bundle, quality_score: 0.7, cost_cents: 30) }
        bundle
      end

      stats = described_class.call(project: project)

      expect(stats[:summary][:bundle_count]).to eq(12)
      expect(stats[:summary][:reviewable_bundle_count]).to eq(12)
      expect(stats[:bundle_rankings].size).to eq(described_class::MAX_BUNDLE_ROWS)
    end

    it "includes Pareto-efficient bundles in tradeoff_frontier even beyond MAX_BUNDLE_ROWS" do
      # Create MAX_BUNDLE_ROWS bundles with high quality (these fill the rankings table)
      Array.new(described_class::MAX_BUNDLE_ROWS) do |i|
        bundle = create(:configuration_bundle, account: project.account, definition: {
          "schema_version" => 1, "goal" => "create_pr", "agent_type" => "claude_code", "experiments" => {}
        })
        create_bundle_outcome(project: project, bundle: bundle, quality_score: 0.9 - (i * 0.01), cost_cents: 100)
        bundle
      end

      # Create a bundle outside the top rankings that is Pareto-efficient (low cost, moderate quality)
      pareto_bundle = create(:configuration_bundle, account: project.account, definition: {
        "schema_version" => 1, "goal" => "create_pr", "agent_type" => "claude_code", "experiments" => {}
      })
      create_bundle_outcome(project: project, bundle: pareto_bundle, quality_score: 0.5, cost_cents: 5)

      stats = described_class.call(project: project)

      # The pareto bundle should NOT be in bundle_rankings (capped at MAX_BUNDLE_ROWS)
      ranking_bundles = stats[:bundle_rankings].map { |r| r[:bundle] }
      expect(ranking_bundles).not_to include(pareto_bundle)

      # But it SHOULD appear in tradeoff_frontier (computed from full set)
      frontier_bundles = stats[:tradeoff_frontier].map { |r| r[:bundle] }
      expect(frontier_bundles).to include(pareto_bundle)
    end

    it "is not sparse when optimizer insights have candidates despite no outcomes or experiments" do
      run = create(:agent_run, project: project, issue: create(:issue, project: project), goal: "create_pr")

      allow(ConfigurationBundles::Optimizer).to receive(:ranked_candidates).and_return([])
      allow(ConfigurationBundles::Optimizer).to receive(:ranked_candidates)
        .with(agent_run: run)
        .and_return([ mock_optimizer_selection ])

      stats = described_class.call(project: project)

      expect(stats[:summary][:outcome_count]).to eq(0)
      expect(stats[:summary][:active_experiment_count]).to eq(0)
      expect(stats[:sparse]).to be(false)
    end

    it "excludes other projects from experiment variant stats" do
      other_project = create(:project, account: project.account)
      experiment, control, variant = create_experiment(project: project)
      create_bundle(project: project, experiment: experiment, variant: variant)

      create_assignment(project: other_project, experiment: experiment, variant: control, quality_scores: [ 0.9, 0.95 ])
      create_assignment(project: other_project, experiment: experiment, variant: variant, quality_scores: [ 0.1, 0.15 ])
      create_assignment(project: project, experiment: experiment, variant: control, quality_scores: [ 0.4, 0.5 ])
      create_assignment(project: project, experiment: experiment, variant: variant, quality_scores: [ 0.8, 0.84 ])

      stats = described_class.call(project: project)

      control_variant = stats[:experiment_confidence].first[:variants].find { |v| v[:is_control] }
      treatment_variant = stats[:experiment_confidence].first[:variants].find { |v| !v[:is_control] }

      expect(control_variant[:sample_count]).to eq(2)
      expect(treatment_variant[:sample_count]).to eq(2)
      expect(treatment_variant[:avg_quality_score]).to be_within(0.001).of(0.82)
    end

    it "only counts experiments that are active for the project" do
      selected_experiment, selected_control, selected_variant = create_experiment(
        project: project,
        config_key: "knowledge.token_budget"
      )
      create_bundle(project:, experiment: selected_experiment, variant: selected_variant)
      populate_experiment(project:, experiment: selected_experiment, control: selected_control, variant: selected_variant)

      create_experiment(
        project: project,
        account: nil,
        config_key: "knowledge.token_budget"
      )

      create_experiment(
        project: project,
        config_key: "knowledge.section_order",
        traffic_percentage: 0
      )

      stats = described_class.call(project: project)

      expect(stats[:summary][:active_experiment_count]).to eq(1)
      expect(stats[:experiment_confidence].map { |row| row[:experiment] }).to eq([ selected_experiment ])
    end

    it "loads experiment variants once per experiment when building confidence stats" do
      experiment, control, variant = create_experiment(project:)
      create_bundle(project:, experiment:, variant:)
      populate_experiment(project:, experiment:, control:, variant:)
      allow(ConfigurationBundles::Optimizer).to receive(:ranked_candidates).and_return([])

      queries = capture_queries { described_class.call(project: project) }
      variant_queries = queries.grep(/FROM "configuration_experiment_variants"/)

      expect(variant_queries.size).to eq(1)
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

  def create_experiment(project:, account: project.account, config_key: "knowledge.token_budget", traffic_percentage: 100)
    experiment = create(:configuration_experiment,
      account: account,
      status: "running",
      config_key: config_key,
      traffic_percentage: traffic_percentage,
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

  def mock_optimizer_selection
    score_inputs = ConfigurationBundles::Optimizer::ScoreInputs.new(
      predicted_quality_score: 0.8,
      uncertainty: 0.1,
      sample_count: 5,
      acquisition_score: 0.84
    )

    ConfigurationBundles::Optimizer::Selection.new(
      definition: { "schema_version" => 1, "goal" => "create_pr", "agent_type" => "claude_code", "experiments" => {} },
      fingerprint: "mock_fingerprint",
      variant_by_experiment_id: {},
      score_inputs: score_inputs
    )
  end
end
