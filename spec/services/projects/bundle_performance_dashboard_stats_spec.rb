# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::BundlePerformanceDashboardStats do
  describe ".call" do
    let(:project) { create(:project) }
    let(:project_issue) { create(:issue, project: project) }
    let(:shared_issues) { {} }

    it "returns a sparse payload with no outcomes or experiments" do
      stats = described_class.call(project: project)

      expect(stats[:sparse]).to be(true)
      expect(stats[:bundle_rankings]).to eq([])
      expect(stats[:tradeoff_frontier]).to eq([])
      expect(stats[:experiment_confidence]).to eq([])
    end

    it "computes summary counts from all bundles, not just the displayed rows" do
      stub_const("#{described_class}::MIN_REVIEWABLE_SAMPLE_SIZE", 1)
      bundle_count = described_class::MAX_BUNDLE_ROWS + 1

      Array.new(bundle_count) do
        bundle = create(:configuration_bundle, account: project.account, definition: {
          "schema_version" => 1, "goal" => "create_pr", "agent_type" => "claude_code", "experiments" => {}
        })
        create_bundle_outcome(project: project, bundle: bundle, quality_score: 0.7, cost_cents: 30)
        bundle
      end

      stats = described_class.call(project: project)

      expect(stats[:summary][:bundle_count]).to eq(bundle_count)
      expect(stats[:summary][:reviewable_bundle_count]).to eq(bundle_count)
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

    it "recomputes objective scores for historical outcomes missing persisted metrics" do
      expensive_bundle = create_simple_bundle(project:)
      create_bundle_outcome(
        project: project,
        bundle: expensive_bundle,
        quality_score: 0.8,
        cost_cents: 10_000,
        metrics: {}
      )

      efficient_bundle = create_simple_bundle(project:)
      create_bundle_outcome(
        project: project,
        bundle: efficient_bundle,
        quality_score: 0.79,
        cost_cents: 10
      )

      stats = described_class.call(project: project)

      expect(stats[:bundle_rankings].first[:bundle]).to eq(efficient_bundle)
      expect(stats[:bundle_rankings].find { |row| row[:bundle] == expensive_bundle }[:avg_objective_score]).to be < 0.8
      expect(stats[:tradeoff_frontier].first[:bundle]).to eq(efficient_bundle)
    end

    it "is not sparse when optimizer insights have candidates despite no outcomes or experiments" do
      run = create(:agent_run, project: project, issue: project_issue, goal: "create_pr")

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

    it "excludes running experiments from other accounts even when rollout membership matches" do
      selected_experiment, = create_experiment(project:)
      other_account_project = create(:project)
      create_experiment(project: other_account_project)

      stats = described_class.call(project: project)

      expect(stats[:summary][:active_experiment_count]).to eq(1)
      expect(stats[:experiment_confidence].map { |row| row[:experiment] }).to eq([ selected_experiment ])
    end

    it "includes active project experiments before they have assignment data" do
      experiment, = create_experiment(project:)

      stats = described_class.call(project: project)

      expect(stats[:summary][:active_experiment_count]).to eq(1)
      expect(stats[:experiment_confidence].map { |row| row[:experiment] }).to eq([ experiment ])
      expect(stats[:experiment_confidence].first[:variants]).to all(include(sample_count: 0, sparse: true))
      expect(stats[:sparse_details][:sparse_experiment_count]).to eq(1)
    end

    it "keeps assignment-backed active experiments visible when project rollout excludes the project" do
      experiment, control, variant = create_experiment(project:, traffic_percentage: 50)
      assigned_project, assigned_runs = create_assignment_backed_project_for(experiment, run_count: 2)
      control_run, variant_run = assigned_runs

      create(:configuration_experiment_assignment,
        configuration_experiment: experiment,
        configuration_experiment_variant: control,
        agent_run: control_run,
        quality_score: 0.4)
      create(:configuration_experiment_assignment,
        configuration_experiment: experiment,
        configuration_experiment_variant: variant,
        agent_run: variant_run,
        quality_score: 0.8)

      stats = described_class.call(project: assigned_project)

      expect(experiment.includes_traffic?(project: assigned_project)).to be(false)
      expect(assigned_runs).to all(satisfy { |run| experiment.includes_traffic?(agent_run: run) })
      expect(stats[:summary][:active_experiment_count]).to eq(1)
      expect(stats[:experiment_confidence].map { |row| row[:experiment] }).to eq([ experiment ])
      expect(stats[:experiment_confidence].first[:variants].map { |row| row[:sample_count] }).to eq([ 1, 1 ])
    end

    it "prefers the runtime-active experiment over assignment-backed history for the same config key" do
      global_experiment, = create_experiment(project:, account: nil, config_key: "knowledge.token_budget")
      stale_experiment, stale_control, stale_variant = create_experiment(project:, config_key: "knowledge.token_budget", traffic_percentage: 50)
      assigned_project, assigned_runs = create_assignment_backed_project_for(stale_experiment, run_count: 2)
      control_run, variant_run = assigned_runs

      create(:configuration_experiment_assignment,
        configuration_experiment: stale_experiment,
        configuration_experiment_variant: stale_control,
        agent_run: control_run,
        quality_score: 0.4)
      create(:configuration_experiment_assignment,
        configuration_experiment: stale_experiment,
        configuration_experiment_variant: stale_variant,
        agent_run: variant_run,
        quality_score: 0.8)

      stats = described_class.call(project: assigned_project)

      expect(stale_experiment.includes_traffic?(project: assigned_project)).to be(false)
      expect(ConfigurationExperiment.active_for("knowledge.token_budget", project: assigned_project)).to eq(global_experiment)
      expect(stats[:summary][:active_experiment_count]).to eq(1)
      expect(stats[:experiment_confidence].map { |row| row[:experiment] }).to eq([ global_experiment ])
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
      expect(stats[:bundle_rankings].first[:avg_objective_score]).to be < stats[:bundle_rankings].first[:avg_quality_score]
      expect(stats[:bundle_rankings].first[:avg_quality_per_dollar]).to be > 1
      expect(stats[:bundle_rankings].first[:avg_quality_score]).to be_within(0.001).of(0.85)
      expect(stats[:experiment_confidence].first[:variants].size).to eq(2)
      expect(stats[:tradeoff_frontier].first[:bundle]).to eq(bundle)
      candidate = optimizer_candidate_for(stats, goal: "create_pr")

      expect(candidate).to include(
        acquisition_function: "expected_improvement"
      )
      expect(candidate[:best_observed_objective_score]).to eq(
        expected_best_observed_objective_score_for(stats, goal: "create_pr")
      )
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

  def create_simple_bundle(project:)
    create(:configuration_bundle, account: project.account, definition: {
      "schema_version" => 1, "goal" => "create_pr", "agent_type" => "claude_code", "experiments" => {}
    })
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
    issue = shared_issue_for(project)

    quality_scores.each do |score|
      run = create(:agent_run,
        :completed,
        project: project,
        issue: issue,
        goal: "create_pr")
      create(:configuration_experiment_assignment,
        configuration_experiment: experiment,
        configuration_experiment_variant: variant,
        agent_run: run,
        quality_score: score)
    end
  end

  def create_bundle_outcome(project:, bundle:, quality_score:, cost_cents:, metrics: nil)
    issue = shared_issue_for(project)

    run = create(:agent_run,
      :completed,
      project: project,
      issue: issue,
      goal: "create_pr",
      configuration_bundle: bundle,
      cost_cents: cost_cents)

    objective = ConfigurationBundles::ObjectiveScore.call(
      project: project,
      quality_score: quality_score,
      cost_cents: cost_cents,
      duration_seconds: run.duration_seconds
    )

    create(:bundle_outcome,
      configuration_bundle: bundle,
      agent_run: run,
      quality_score: quality_score,
      cost_cents: cost_cents,
      duration_seconds: run.duration_seconds,
      metrics: metrics || {
        "objective_score" => objective.objective_score,
        "quality_per_dollar" => objective.quality_per_dollar
      },
      success: true)
  end

  def optimizer_candidate_for(stats, goal:)
    stats[:optimizer_insights].find { |row| row[:goal] == goal }.fetch(:candidates).first
  end

  def expected_best_observed_objective_score_for(stats, goal:)
    representative_run = stats[:optimizer_insights].find { |row| row[:goal] == goal }.fetch(:representative_run)

    BundleOutcome
      .where(agent_run: project.agent_runs.where(goal: goal))
      .where.not(id: representative_run.bundle_outcomes.select(:id))
      .filter_map { |outcome| ConfigurationBundles::ObjectiveScore.from_outcome(outcome) }
      .max
  end

  def shared_issue_for(project)
    shared_issues[project.id] ||= create(:issue, project: project)
  end

  def create_assignment_backed_project_for(experiment, run_count:)
    50.times do
      project = create(:project, account: experiment.account)
      next if experiment.includes_traffic?(project: project)

      runs = Array.new(run_count) do
        create(:agent_run,
          :completed,
          project: project,
          issue: create(:issue, project: project),
          goal: "create_pr")
      end

      next unless runs.all? { |run| experiment.includes_traffic?(agent_run: run) }

      return [ project, runs ]
    end

    raise "Could not create a project excluded from project rollout with included assigned runs"
  end

  def mock_optimizer_selection
    score_inputs = ConfigurationBundles::Optimizer::ScoreInputs.new(
      predicted_objective_score: 0.76,
      predicted_quality_score: 0.8,
      uncertainty: 0.1,
      sample_count: 5,
      best_observed_objective_score: 0.71,
      acquisition_function: "expected_improvement",
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
