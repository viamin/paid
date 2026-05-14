# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::Optimizer do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project, issue: create(:issue, project: project)) }
  let(:surrogate_model) { instance_double(ConfigurationBundles::SurrogateOutcomeModel) }
  let(:experiment) do
    create(:configuration_experiment,
      account: project.account,
      status: "running",
      config_key: "knowledge.token_budget",
      control_value: JSON.generate(4000))
  end
  let!(:control) do
    create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(4000),
      is_control: true)
  end
  let!(:challenger) do
    create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(8000))
  end

  describe ".call" do
    it "selects the candidate with the highest acquisition score" do
      create_bundle_history(
        experiment: experiment,
        variant: control,
        quality_scores: [ 0.62, 0.64, 0.66, 0.68 ]
      )
      create_bundle_history(
        experiment: experiment,
        variant: challenger,
        quality_scores: [ 0.98 ]
      )

      selection = described_class.call(agent_run: agent_run)

      expect(selection.variant_by_experiment_id).to eq(experiment.id => challenger)
      expect(selection.score_inputs.predicted_objective_score).to be > 0
      expect(selection.score_inputs.predicted_quality_score).to be > 0
      expect(selection.score_inputs.uncertainty).to be > 0
      expect(selection.score_inputs.acquisition_function).to eq("expected_improvement")
      expect(selection.score_inputs.best_observed_objective_score).to be > 0
      expect(selection.score_inputs.acquisition_score).to be > 0
    end

    it "routes no-issue runs through the project exploration budget" do
      set_exploration_budgets(project: 100)
      run = create(:agent_run, :create_issue_goal, project: project)
      stub_predictions(run, surrogate_model:)

      selection = described_class.call(agent_run: run, surrogate_model: surrogate_model)

      expect(selection.variant_by_experiment_id).to eq(experiment.id => challenger)
      expect(selection.selection_mode).to eq("exploratory")
      expect(selection.selection_context).to eq("project")
      expect_budget_snapshot(selection, "project", projected_share: 1.0, within_budget: true)
    end

    it "blocks a first exploratory project run that would exceed the configured budget" do
      set_exploration_budgets(project: 25)
      run = create(:agent_run, :create_issue_goal, project: project)
      stub_predictions(run, surrogate_model:)

      selection = described_class.call(agent_run: run, surrogate_model: surrogate_model)

      expect(selection.variant_by_experiment_id).to eq(experiment.id => control)
      expect(selection.selection_mode).to eq("exploitative")
      expect(selection.selection_context).to eq("project")
      expect_budget_snapshot(selection, "project",
        budget: 0.25,
        total_runs: 0,
        exploratory_runs: 0,
        observed_share: 0.0,
        projected_share: 1.0,
        within_budget: false
      )
    end

    it "enforces the project exploration budget before choosing an exploratory bundle" do
      set_exploration_budgets(project: 25)
      seed_project_budget_history(project:, goal: agent_run.goal)
      stub_predictions(agent_run, surrogate_model:)

      selection = described_class.call(agent_run: agent_run, surrogate_model: surrogate_model)

      expect(selection.variant_by_experiment_id).to eq(experiment.id => control)
      expect(selection.selection_mode).to eq("exploitative")
      expect_budget_snapshot(selection, "project",
        budget: 0.25,
        exploratory_runs: 1,
        total_runs: 4,
        observed_share: 0.25,
        projected_share: 0.4,
        within_budget: false
      )
    end

    it "enforces the task exploration budget even when the project budget allows exploration" do
      set_exploration_budgets(task: 0, project: 100)
      stub_predictions(agent_run, surrogate_model:)

      selection = described_class.call(agent_run: agent_run, surrogate_model: surrogate_model)

      expect(selection.variant_by_experiment_id).to eq(experiment.id => control)
      expect(selection.selection_mode).to eq("exploitative")
      expect(selection.selection_context).to eq("task")
      expect_budget_snapshot(selection, "task", projected_share: 1.0, within_budget: false)
      expect_budget_snapshot(selection, "project", projected_share: 1.0, within_budget: true)
    end

    it "bootstraps task exploration from the project budget until the issue has enough routing history" do
      set_exploration_budgets(task: 10, project: 100)
      stub_predictions(agent_run, surrogate_model:)

      selection = described_class.call(agent_run: agent_run, surrogate_model: surrogate_model)

      expect(selection.variant_by_experiment_id).to eq(experiment.id => challenger)
      expect(selection.selection_mode).to eq("exploratory")
      expect(selection.selection_context).to eq("project")
      expect_budget_snapshot(selection, "task",
        budget: 0.1,
        total_runs: 0,
        exploratory_runs: 0,
        projected_share: 1.0,
        within_budget: true,
        bootstrap_active: true,
        bootstrap_minimum_runs: 9
      )
      expect_budget_snapshot(selection, "project", projected_share: 1.0, within_budget: true)
    end

    it "records project context when task routing is still bootstrapping and project budget blocks exploration" do
      set_exploration_budgets(task: 10, project: 25)
      seed_project_budget_history(project:, goal: agent_run.goal)
      stub_predictions(agent_run, surrogate_model:)

      selection = described_class.call(agent_run: agent_run, surrogate_model: surrogate_model)

      expect(selection.variant_by_experiment_id).to eq(experiment.id => control)
      expect(selection.selection_mode).to eq("exploitative")
      expect(selection.selection_context).to eq("project")
      expect_task_bootstrap_snapshot(selection)
      expect_project_budget_block(selection)
    end

    it "returns nil when there are no active tracked experiments" do
      experiment.update!(status: "completed", completed_at: Time.current)

      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "prefers the cheaper bundle when quality is matched" do
      create_bundle_history(
        experiment: experiment,
        variant: control,
        quality_scores: [ 0.8, 0.8 ],
        cost_cents: 25
      )
      create_bundle_history(
        experiment: experiment,
        variant: challenger,
        quality_scores: [ 0.8, 0.8 ],
        cost_cents: 200
      )

      selection = described_class.call(agent_run: agent_run)

      expect(selection.variant_by_experiment_id).to eq(experiment.id => control)
      expect(selection.score_inputs.predicted_objective_score).to be <= selection.score_inputs.predicted_quality_score
    end

    it "skips malformed variants while still scoring valid candidates" do
      challenger.update!(config_value: "{not-json")
      create_bundle_history(
        experiment: experiment,
        variant: control,
        quality_scores: [ 0.72, 0.74 ]
      )

      selection = described_class.call(agent_run: agent_run)

      expect(selection.variant_by_experiment_id).to eq(experiment.id => control)
      expect(selection.definition.dig("experiments", experiment.config_key, "value")).to eq(4000)
    end

    it "learns from prior outcomes when an experiment is recreated with the same value" do
      create_prior_history
      experiment.update!(status: "completed", completed_at: Time.current)

      recreated_experiment, recreated_control, recreated_challenger = recreate_experiment

      selection = described_class.call(agent_run: agent_run)

      expect(selection.variant_by_experiment_id).to eq(recreated_experiment.id => recreated_challenger)
      expect(selection.definition.dig("experiments", experiment.config_key, "value")).to eq(8000)
      expect(selection.definition.dig("experiments", experiment.config_key, "configuration_experiment_variant_id")).to eq(recreated_challenger.id)
      expect(recreated_challenger.id).not_to eq(challenger.id)
      expect(recreated_control.id).not_to eq(control.id)
    end
  end

  describe ".ranked_candidates" do
    it "returns candidates sorted by acquisition score" do
      create_bundle_history(
        experiment: experiment,
        variant: control,
        quality_scores: [ 0.65, 0.66, 0.67 ]
      )
      create_bundle_history(
        experiment: experiment,
        variant: challenger,
        quality_scores: [ 0.9, 0.91 ]
      )

      ranked = described_class.ranked_candidates(agent_run: agent_run)

      expect(ranked.map(&:score_inputs).map(&:acquisition_score)).to eq(
        ranked.map(&:score_inputs).map(&:acquisition_score).sort.reverse
      )
      expect(ranked.first.variant_by_experiment_id).to eq(experiment.id => challenger)
    end

    it "scores candidates against the best observed objective for the goal" do
      create_bundle_history(
        experiment: experiment,
        variant: challenger,
        quality_scores: [ 0.95 ]
      )
      create_bundle_history(
        experiment: experiment,
        variant: control,
        quality_scores: [ 0.7, 0.72, 0.74 ]
      )

      ranked = described_class.ranked_candidates(agent_run: agent_run)

      expect(ranked).to all(have_attributes(score_inputs: have_attributes(acquisition_function: "expected_improvement")))
      expect(ranked.first.score_inputs.best_observed_objective_score).to be > 0
      expect(ranked.first.score_inputs.acquisition_score).to be <= ranked.first.score_inputs.uncertainty +
        ranked.first.score_inputs.predicted_objective_score
    end

    it "keeps the incumbent from older outcomes outside the surrogate training window" do
      create_bundle_history(
        experiment: experiment,
        variant: challenger,
        quality_scores: [ 0.4 ],
        objective_scores: [ 1.25 ],
        created_at: 2.years.ago
      )
      create_bundle_history(
        experiment: experiment,
        variant: control,
        quality_scores: Array.new(ConfigurationBundles::SurrogateModel::MAX_OUTCOME_ROWS, 0.7),
        objective_scores: Array.new(ConfigurationBundles::SurrogateModel::MAX_OUTCOME_ROWS, 0.7)
      )

      ranked = described_class.ranked_candidates(agent_run: agent_run)

      expect(ranked).to all(have_attributes(score_inputs: have_attributes(best_observed_objective_score: 1.25)))
    end

    it "loads experiment variants in a single query" do
      create_bundle_history(
        experiment: experiment,
        variant: control,
        quality_scores: [ 0.65, 0.66, 0.67 ]
      )
      create_bundle_history(
        experiment: experiment,
        variant: challenger,
        quality_scores: [ 0.9, 0.91 ]
      )

      queries = capture_queries { described_class.ranked_candidates(agent_run: agent_run) }

      expect(queries.grep(/FROM "configuration_experiment_variants"/).size).to eq(1)
    end

    it "does not issue per-outcome agent_run or project queries when objective scores are computed" do
      create_bundle_history(
        experiment: experiment,
        variant: control,
        quality_scores: [ 0.65, 0.66, 0.67 ]
      )
      create_bundle_history(
        experiment: experiment,
        variant: challenger,
        quality_scores: [ 0.9, 0.91 ]
      )
      BundleOutcome.update_all(metrics: {})

      queries = capture_queries { described_class.ranked_candidates(agent_run: agent_run) }

      expect(queries.grep(/FROM "bundle_outcomes"/).size).to be <= 2
      expect(queries.grep(/FROM "agent_runs"/).size).to eq(0)
      expect(queries.grep(/FROM "projects"/).size).to eq(0)
    end
  end

  def create_prior_history
    create_bundle_history(
      experiment: experiment,
      variant: control,
      quality_scores: [ 0.65, 0.67 ]
    )
    create_bundle_history(
      experiment: experiment,
      variant: challenger,
      quality_scores: [ 0.9, 0.92 ]
    )
  end

  def recreate_experiment
    recreated_experiment = create(:configuration_experiment,
      account: project.account,
      status: "running",
      config_key: experiment.config_key,
      control_value: JSON.generate(4000))
    recreated_control = create(:configuration_experiment_variant,
      configuration_experiment: recreated_experiment,
      config_value: JSON.generate(4000),
      is_control: true)
    recreated_challenger = create(:configuration_experiment_variant,
      configuration_experiment: recreated_experiment,
      config_value: JSON.generate(8000))

    [ recreated_experiment, recreated_control, recreated_challenger ]
  end

  def stub_predictions(_run, surrogate_model:)
    allow(surrogate_model).to receive(:predict) do |bundle_definition:, **|
      variant_id = bundle_definition.dig("experiments", experiment.config_key, "configuration_experiment_variant_id")
      prediction_for(variant_id == control.id ? :exploitative : :exploratory)
    end
  end

  def set_exploration_budgets(**budgets)
    project.update!(fitness_settings: {
      "configuration_bundle_optimizer" => {
        "exploration_budgets" => budgets.transform_keys(&:to_s)
      }
    })
  end

  def expect_budget_snapshot(selection, context, expected_values)
    expect(selection.budget_snapshot.fetch(context)).to include(expected_values)
  end

  def expect_task_bootstrap_snapshot(selection)
    expect_budget_snapshot(selection, "task",
      budget: 0.1,
      total_runs: 0,
      exploratory_runs: 0,
      projected_share: 1.0,
      within_budget: true,
      bootstrap_active: true,
      bootstrap_minimum_runs: 9
    )
  end

  def expect_project_budget_block(selection)
    expect_budget_snapshot(selection, "project",
      budget: 0.25,
      exploratory_runs: 1,
      total_runs: 4,
      observed_share: 0.25,
      projected_share: 0.4,
      within_budget: false
    )
  end

  def prediction_for(mode)
    if mode == :exploitative
      ConfigurationBundles::SurrogateOutcomeModel::Prediction.new(
        predicted_objective_score: 0.82,
        predicted_quality_score: 0.82,
        predicted_success_probability: 0.9,
        predicted_cost_cents: 50,
        predicted_duration_seconds: 120,
        uncertainty: 0.01,
        sample_count: 4,
        trained_at: Time.current
      )
    else
      ConfigurationBundles::SurrogateOutcomeModel::Prediction.new(
        predicted_objective_score: 0.72,
        predicted_quality_score: 0.72,
        predicted_success_probability: 0.6,
        predicted_cost_cents: 80,
        predicted_duration_seconds: 180,
        uncertainty: 0.35,
        sample_count: 1,
        trained_at: Time.current
      )
    end
  end

  def seed_project_budget_history(project:, goal:)
    create(:agent_run, project: project, issue: create(:issue, project: project),
      goal: goal, configuration_bundle_selection_mode: "exploratory")
    3.times do
      create(:agent_run, project: project, issue: create(:issue, project: project),
        goal: goal, configuration_bundle_selection_mode: "exploitative")
    end
  end

  def create_bundle_history(experiment:, variant:, quality_scores:, cost_cents: 40, objective_scores: nil, created_at: Time.current)
    definition = {
      "schema_version" => 1,
      "goal" => agent_run.goal,
      "agent_type" => agent_run.agent_type,
      "provider_id" => agent_run.provider_id,
      "prompt_version_id" => agent_run.prompt_version_id,
      "experiments" => {
        experiment.config_key => {
          "configuration_experiment_id" => experiment.id,
          "configuration_experiment_variant_id" => variant.id,
          "value" => variant.parsed_value
        }
      }
    }
    bundle = create(:configuration_bundle, account: project.account, definition: definition)

    quality_scores.each_with_index do |quality_score, index|
      run = create(:agent_run,
        :completed,
        configuration_bundle: bundle,
        project: project,
        issue: create(:issue, project: project),
        cost_cents: cost_cents,
        created_at: created_at)
      create(:bundle_outcome,
        configuration_bundle: bundle,
        agent_run: run,
        quality_score: quality_score,
        cost_cents: cost_cents,
        metrics: objective_scores ? { "objective_score" => objective_scores.fetch(index) } : {},
        created_at: created_at)
    end
  end
end
